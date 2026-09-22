# A REST API, because usage plans, API keys and AWS WAF are REST-only.
#
# None of the three has an HTTP API equivalent and none of them is a setting
# that can be turned on later: an HTTP API cannot issue an API key, cannot be
# metered by a usage plan, and cannot have a web ACL associated with it. An API
# that needs to tell its callers apart, charge or cap them, or sit behind a
# firewall is a REST API from the beginning or it is rebuilt as one.

data "aws_region" "current" {}

locals {
  # ---------------------------------------------------------------------
  # Resource tree
  # ---------------------------------------------------------------------
  #
  # A path is built one segment at a time, and each API Gateway resource names
  # its parent. That cannot be expressed as one resource block with for_each,
  # because Terraform refuses a resource whose configuration references another
  # instance of itself -- it is a cycle at the block level even when the
  # instances form a tree. So the tree is built one depth at a time, and the
  # depth limit below is the number of blocks that exist rather than a service
  # limit. API Gateway itself allows far deeper paths.
  max_path_depth = 5

  method_paths = distinct([for _, m in var.methods : m.path])

  path_segments = {
    for path in local.method_paths : path => compact(split("/", path))
  }

  too_deep_paths = sort([
    for path, segments in local.path_segments : path
    if length(segments) > local.max_path_depth
  ])

  # Every prefix of every path, because /orders/{id} needs /orders to exist
  # even when nothing is served at /orders.
  all_prefixes = distinct(flatten([
    for path, segments in local.path_segments : [
      for i in range(min(length(segments), local.max_path_depth)) :
      join("/", slice(segments, 0, i + 1))
    ]
  ]))

  prefixes_at_depth_1 = toset([for p in local.all_prefixes : p if length(split("/", p)) == 1])
  prefixes_at_depth_2 = toset([for p in local.all_prefixes : p if length(split("/", p)) == 2])
  prefixes_at_depth_3 = toset([for p in local.all_prefixes : p if length(split("/", p)) == 3])
  prefixes_at_depth_4 = toset([for p in local.all_prefixes : p if length(split("/", p)) == 4])
  prefixes_at_depth_5 = toset([for p in local.all_prefixes : p if length(split("/", p)) == 5])

  resource_ids = merge(
    { for prefix, r in aws_api_gateway_resource.depth_1 : "/${prefix}" => r.id },
    { for prefix, r in aws_api_gateway_resource.depth_2 : "/${prefix}" => r.id },
    { for prefix, r in aws_api_gateway_resource.depth_3 : "/${prefix}" => r.id },
    { for prefix, r in aws_api_gateway_resource.depth_4 : "/${prefix}" => r.id },
    { for prefix, r in aws_api_gateway_resource.depth_5 : "/${prefix}" => r.id },
  )

  # A path variable is part of the resource, so /orders/{id} and
  # /orders/{orderId} are two different resources under the same parent and
  # API Gateway refuses the pair. Terraform would create both and fail on the
  # second, leaving the first behind.
  sibling_variable_conflicts = sort(distinct(flatten([
    for prefix in local.all_prefixes : [
      for other in local.all_prefixes :
      format("%s and %s", prefix, other)
      if prefix < other
      && length(split("/", prefix)) == length(split("/", other))
      && join("/", slice(split("/", prefix), 0, length(split("/", prefix)) - 1)) == join("/", slice(split("/", other), 0, length(split("/", other)) - 1))
      && startswith(element(split("/", prefix), length(split("/", prefix)) - 1), "{")
      && startswith(element(split("/", other), length(split("/", other)) - 1), "{")
    ]
  ])))

  # ---------------------------------------------------------------------
  # Metering
  # ---------------------------------------------------------------------

  has_usage_plans = length(var.usage_plans) > 0

  # Unset follows whether there is anything to meter. A method that does not
  # require a key is served without one, and a request served without a key is
  # counted against no plan and reported nowhere.
  default_api_key_required = var.default_api_key_required != null ? var.default_api_key_required : local.has_usage_plans

  api_key_required = {
    for key, method in var.methods :
    key => method.api_key_required != null ? method.api_key_required : local.default_api_key_required
  }

  methods_not_requiring_an_api_key = sort([
    for key, required in local.api_key_required : key if !required
  ])

  methods_reachable_without_authorization = sort([
    for key, method in var.methods : key
    if method.authorization == "NONE" && !local.api_key_required[key]
  ])

  # The two places a method is named in a throttle setting are spelled
  # differently: a stage method setting takes the resource path without its
  # leading slash, and a usage plan throttle takes it with one. Both are
  # derived from the same declaration so the difference cannot be got wrong,
  # and neither is accepted as text -- a string naming no method is stored
  # without complaint and throttles nothing.
  method_setting_paths = {
    for key, method in var.methods :
    key => format("%s/%s", trimprefix(method.path, "/"), method.http_method)
  }

  usage_plan_throttle_paths = {
    for key, method in var.methods :
    key => format("%s/%s", method.path == "/" ? "" : method.path, method.http_method)
  }

  method_throttles_naming_no_method = sort([
    for key, _ in var.method_throttles : key if !contains(keys(var.methods), key)
  ])

  plan_method_throttles_naming_no_method = sort(distinct(flatten([
    for plan_key, plan in var.usage_plans : [
      for method_key, _ in plan.method_throttles :
      format("%s/%s", plan_key, method_key)
      if !contains(keys(var.methods), method_key)
    ]
  ])))

  # A method on the root path has no resource of its own, and the string API
  # Gateway identifies it by in a throttle setting is not one this module will
  # guess. A guessed string is stored without complaint and throttles nothing,
  # which is the failure this derivation exists to remove, so the case is
  # refused by name instead.
  root_method_keys = sort([
    for key, method in var.methods : key if method.path == "/"
  ])

  throttles_naming_a_root_method = sort(distinct(concat(
    [for key, _ in var.method_throttles : key if contains(local.root_method_keys, key)],
    flatten([
      for plan_key, plan in var.usage_plans : [
        for method_key, _ in plan.method_throttles :
        format("%s/%s", plan_key, method_key)
        if contains(local.root_method_keys, method_key)
      ]
    ]),
  )))

  plan_keys_naming_no_key = sort(distinct(flatten([
    for plan_key, plan in var.usage_plans : [
      for key_name in plan.api_keys :
      format("%s/%s", plan_key, key_name)
      if !contains(keys(var.api_keys), key_name)
    ]
  ])))

  # Only pairs whose key was actually declared. A pair naming a key that does
  # not exist is refused by the guard below, by name, rather than failing on a
  # missing map entry somewhere further down.
  plan_key_pairs = merge([
    for plan_key, plan in var.usage_plans : {
      for key_name in plan.api_keys :
      "${plan_key}/${key_name}" => {
        plan_key = plan_key
        key_name = key_name
      }
      if contains(keys(var.api_keys), key_name)
    }
  ]...)

  keys_not_attached_to_any_plan = sort([
    for key_name, _ in var.api_keys : key_name
    if length([for _, pair in local.plan_key_pairs : pair if pair.key_name == key_name]) == 0
  ])

  # A plan limit applies to each key separately, so the traffic the stage can
  # see is the plan's rate multiplied by the number of keys on it. That number
  # goes up every time a client is added, with nothing reconfigured and nothing
  # reported. The stage throttle is the only thing that bounds the total.
  plan_aggregate_rate = {
    for plan_key, plan in var.usage_plans :
    plan_key => plan.throttle == null ? null : plan.throttle.rate_limit * length(plan.api_keys)
  }

  total_plan_rate_if_every_key_is_at_its_limit = sum(concat([0], [
    for _, rate in local.plan_aggregate_rate : rate if rate != null
  ]))

  plans_above_the_stage_throttle = var.stage_throttle == null ? [] : sort([
    for plan_key, rate in local.plan_aggregate_rate : plan_key
    if rate != null && rate > var.stage_throttle.rate_limit
  ])

  # ---------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------

  access_log_group_name = "/aws/apigateway/${var.name}/${var.stage_name}/access"

  # The fields chosen are the ones that separate causes rather than restate the
  # response. status and integrationStatus differ exactly when API Gateway
  # changed the answer the backend gave; integrationErrorMessage is the only
  # place the reason for a 5xx is written down; and apiKeyId is what makes a
  # throttled request attributable to a caller rather than to the stage.
  access_log_format = jsonencode({
    requestId               = "$context.requestId"
    ip                      = "$context.identity.sourceIp"
    requestTime             = "$context.requestTime"
    httpMethod              = "$context.httpMethod"
    resourcePath            = "$context.resourcePath"
    status                  = "$context.status"
    integrationStatus       = "$context.integration.status"
    integrationErrorMessage = "$context.integration.error"
    integrationLatency      = "$context.integration.latency"
    responseLatency         = "$context.responseLatency"
    apiKeyId                = "$context.identity.apiKeyId"
    usagePlanId             = "$context.identity.apiKey"
    authorizerError         = "$context.authorizer.error"
    errorMessage            = "$context.error.message"
    errorResponseType       = "$context.error.responseType"
    wafStatus               = "$context.wafResponseCode"
  })

  # ---------------------------------------------------------------------
  # Protection
  # ---------------------------------------------------------------------

  web_acl_region         = var.web_acl_arn == null ? null : split(":", var.web_acl_arn)[3]
  web_acl_in_this_region = var.web_acl_arn == null ? true : local.web_acl_region == data.aws_region.current.name
}

# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "this" {
  name        = var.name
  description = var.description

  api_key_source = var.api_key_source

  endpoint_configuration {
    types = [var.endpoint_type]
  }

  tags = var.tags
}

# The path guards live on a node of their own rather than on the API. A
# precondition becomes part of the dependencies of whatever resource carries
# it, so a check that reads the method table would make the API's identifier
# depend on that table -- and every resource below needs the identifier.
resource "terraform_data" "path_tree" {
  input = local.method_paths

  lifecycle {
    precondition {
      condition = length(local.too_deep_paths) == 0
      error_message = format(
        "These paths are deeper than %d segments, which is as far as this module builds the resource tree: %s. The limit is this module's rather than API Gateway's; deepening it means adding another depth block, because Terraform refuses a resource block that references another instance of itself and an API Gateway resource names its parent.",
        local.max_path_depth,
        join(", ", local.too_deep_paths)
      )
    }

    precondition {
      condition = length(local.sibling_variable_conflicts) == 0
      error_message = format(
        "These path variables are siblings under the same parent: %s. API Gateway allows one variable segment per parent whatever it is called, so the second is refused after the first has already been created.",
        join("; ", local.sibling_variable_conflicts)
      )
    }
  }
}

resource "aws_api_gateway_resource" "depth_1" {
  for_each = local.prefixes_at_depth_1

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = each.value
}

resource "aws_api_gateway_resource" "depth_2" {
  for_each = local.prefixes_at_depth_2

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.depth_1[join("/", slice(split("/", each.value), 0, 1))].id
  path_part   = element(split("/", each.value), 1)
}

resource "aws_api_gateway_resource" "depth_3" {
  for_each = local.prefixes_at_depth_3

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.depth_2[join("/", slice(split("/", each.value), 0, 2))].id
  path_part   = element(split("/", each.value), 2)
}

resource "aws_api_gateway_resource" "depth_4" {
  for_each = local.prefixes_at_depth_4

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.depth_3[join("/", slice(split("/", each.value), 0, 3))].id
  path_part   = element(split("/", each.value), 3)
}

resource "aws_api_gateway_resource" "depth_5" {
  for_each = local.prefixes_at_depth_5

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.depth_4[join("/", slice(split("/", each.value), 0, 4))].id
  path_part   = element(split("/", each.value), 4)
}

# ---------------------------------------------------------------------------
# Methods and integrations
# ---------------------------------------------------------------------------

resource "aws_api_gateway_method" "this" {
  for_each = var.methods

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = each.value.path == "/" ? aws_api_gateway_rest_api.this.root_resource_id : local.resource_ids[each.value.path]
  http_method = each.value.http_method

  authorization        = each.value.authorization
  authorizer_id        = each.value.authorizer_id
  authorization_scopes = length(each.value.authorization_scopes) > 0 ? each.value.authorization_scopes : null

  # Derived rather than typed. This field defaults to false in the API itself,
  # and false here is the difference between a metered API and one that looks
  # metered from every page of the console.
  api_key_required = local.api_key_required[each.key]

  request_parameters = each.value.request_parameters
}

resource "aws_api_gateway_integration" "this" {
  for_each = var.methods

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_method.this[each.key].resource_id
  http_method = aws_api_gateway_method.this[each.key].http_method

  type = each.value.integration.type
  uri  = each.value.integration.uri

  # The verb the integration is called with, which is not the verb the client
  # used. A Lambda proxy integration is always invoked with POST whatever the
  # method is, because the invocation is an API call to Lambda rather than a
  # forwarded request.
  integration_http_method = each.value.integration.type == "MOCK" ? null : each.value.integration.integration_http_method

  connection_type = each.value.integration.connection_type
  connection_id   = each.value.integration.connection_id

  timeout_milliseconds = each.value.integration.timeout_milliseconds

  request_parameters = each.value.integration.request_parameters

  # A MOCK integration reaches nothing, so it needs a request template that
  # tells API Gateway which response to select. Without one it answers 500.
  request_templates = each.value.integration.type == "MOCK" ? merge(
    { "application/json" = "{\"statusCode\": 200}" },
    each.value.integration.request_templates,
  ) : each.value.integration.request_templates
}

resource "aws_api_gateway_method_response" "mock" {
  for_each = { for key, method in var.methods : key => method if method.integration.type == "MOCK" }

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_method.this[each.key].resource_id
  http_method = aws_api_gateway_method.this[each.key].http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "mock" {
  for_each = { for key, method in var.methods : key => method if method.integration.type == "MOCK" }

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_method.this[each.key].resource_id
  http_method = aws_api_gateway_method.this[each.key].http_method
  status_code = aws_api_gateway_method_response.mock[each.key].status_code

  response_templates = {
    "application/json" = jsonencode({ status = "ok" })
  }

  depends_on = [aws_api_gateway_integration.this]
}

# ---------------------------------------------------------------------------
# Deployment and stage
# ---------------------------------------------------------------------------

# A deployment is a snapshot, and a stage serves the snapshot it was given.
# Changing a method or an integration changes nothing a client can see until a
# new deployment is created, and nothing reports that: the console shows the
# new configuration, the API serves the old one, and a route added this way
# answers {"message":"Not Found"}.
#
# The trigger is a hash of everything a deployment captures, so any change to
# it produces a new deployment. create_before_destroy is what stops the stage
# being left pointing at a deployment that is being removed.
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      var.methods,
      var.api_key_source,
      local.api_key_required,
      local.all_prefixes,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_method.this,
    aws_api_gateway_integration.this,
    aws_api_gateway_integration_response.mock,
  ]
}

resource "aws_cloudwatch_log_group" "access" {
  name              = local.access_log_group_name
  retention_in_days = var.access_log_retention_days
  kms_key_id        = var.access_log_kms_key_arn

  tags = var.tags
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name

  xray_tracing_enabled = var.xray_tracing_enabled

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format          = local.access_log_format
  }

  tags = var.tags
}

# The stage-wide entry is the only aggregate ceiling this API has. Every usage
# plan limit below it is per key, so the traffic the stage can receive is the
# sum over plans of rate times keys, and that rises whenever a client is added.
resource "aws_api_gateway_method_settings" "stage_default" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = var.metrics_enabled

    # -1 is how API Gateway is told a limit is unset. Zero would be a limit of
    # zero requests, which is a different thing entirely.
    throttling_rate_limit  = var.stage_throttle == null ? -1 : var.stage_throttle.rate_limit
    throttling_burst_limit = var.stage_throttle == null ? -1 : var.stage_throttle.burst_limit
  }
}

# Filtered to the throttles that name a real, non-root method, so a bad name
# never reaches the derivation. The apply stops at the guard above with the
# name that was wrong, rather than here with a lookup that failed.
resource "aws_api_gateway_method_settings" "per_method" {
  for_each = {
    for key, throttle in var.method_throttles : key => throttle
    if contains(keys(local.method_setting_paths), key) && !contains(local.root_method_keys, key)
  }

  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = lookup(local.method_setting_paths, each.key, "*/*")

  settings {
    metrics_enabled        = var.metrics_enabled
    throttling_rate_limit  = each.value.rate_limit
    throttling_burst_limit = each.value.burst_limit
  }

}

# ---------------------------------------------------------------------------
# Keys and usage plans
# ---------------------------------------------------------------------------

# The generated value is read back into state, so the state for this module
# holds every key it creates. Supplying a value is not offered, because that
# would put the same credential in the configuration as well.
resource "aws_api_gateway_api_key" "this" {
  for_each = var.api_keys

  name        = "${var.name}-${each.key}"
  description = coalesce(each.value.description, "API key ${each.key} for ${var.name}")
  enabled     = each.value.enabled

  tags = var.tags
}

resource "aws_api_gateway_usage_plan" "this" {
  for_each = var.usage_plans

  name        = "${var.name}-${each.key}"
  description = coalesce(each.value.description, "Usage plan ${each.key} for ${var.name}")

  # A plan with no stage meters nothing. It can still be created, still be
  # attached to keys, and still appear to be in force.
  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name

    dynamic "throttle" {
      for_each = {
        for method_key, throttle in each.value.method_throttles : method_key => throttle
        if contains(keys(local.usage_plan_throttle_paths), method_key) && !contains(local.root_method_keys, method_key)
      }

      content {
        path        = lookup(local.usage_plan_throttle_paths, throttle.key, "/")
        rate_limit  = throttle.value.rate_limit
        burst_limit = throttle.value.burst_limit
      }
    }
  }

  dynamic "throttle_settings" {
    for_each = each.value.throttle == null ? toset([]) : toset([1])

    content {
      rate_limit  = each.value.throttle.rate_limit
      burst_limit = each.value.throttle.burst_limit
    }
  }

  dynamic "quota_settings" {
    for_each = each.value.quota == null ? toset([]) : toset([1])

    content {
      limit  = each.value.quota.limit
      period = each.value.quota.period
      offset = each.value.quota.offset
    }
  }

  tags = var.tags

}

resource "aws_api_gateway_usage_plan_key" "this" {
  for_each = local.plan_key_pairs

  key_id        = aws_api_gateway_api_key.this[each.value.key_name].id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this[each.value.plan_key].id
}


# Every name a throttle or a plan uses is checked here rather than on the
# resource that consumes it. A name that matches nothing would otherwise fail
# as a missing map entry, which says where the lookup happened and not which
# declaration was wrong.
resource "terraform_data" "metering" {
  input = {
    plans   = keys(var.usage_plans)
    keys    = keys(var.api_keys)
    methods = keys(var.methods)
  }

  lifecycle {
    precondition {
      condition = length(local.method_throttles_naming_no_method) == 0
      error_message = format(
        "method_throttles names methods that are not declared: %s. API Gateway accepts a throttle setting for a method path that does not exist, stores it, and applies it to nothing.",
        join(", ", local.method_throttles_naming_no_method)
      )
    }

    precondition {
      condition = length(local.plan_method_throttles_naming_no_method) == 0
      error_message = format(
        "These usage plan method throttles name methods that are not declared: %s. The setting is stored against a path the API does not serve and limits nothing.",
        join(", ", local.plan_method_throttles_naming_no_method)
      )
    }

    precondition {
      condition = length(local.throttles_naming_a_root_method) == 0
      error_message = format(
        "These throttles name a method on the root path: %s. A root method has no resource of its own, and this module will not guess the string API Gateway identifies it by -- a wrong one is stored and throttles nothing. Throttle the stage as a whole instead, or move the method under a path.",
        join(", ", local.throttles_naming_a_root_method)
      )
    }

    precondition {
      condition = length(local.plan_keys_naming_no_key) == 0
      error_message = format(
        "These usage plans name API keys that are not declared in api_keys: %s.",
        join(", ", local.plan_keys_naming_no_key)
      )
    }
  }
}

# ---------------------------------------------------------------------------
# Protection
# ---------------------------------------------------------------------------

resource "aws_wafv2_web_acl_association" "this" {
  count = var.web_acl_arn == null ? 0 : 1

  resource_arn = aws_api_gateway_stage.this.arn
  web_acl_arn  = var.web_acl_arn

  lifecycle {
    precondition {
      condition = local.web_acl_in_this_region
      error_message = format(
        "The web ACL is in %s and this API is in %s. A regional web ACL protects resources in its own region only, and the association is refused rather than quietly ignored.",
        coalesce(local.web_acl_region, "an unknown region"),
        data.aws_region.current.name
      )
    }
  }
}
