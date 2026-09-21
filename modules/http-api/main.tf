data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  tags = merge(var.tags, { Name = var.name })

  # The access log format is treated as part of the deliverable rather than as a
  # preference, because an HTTP API has no execution logging at all: unlike a
  # REST API there is no second stream recording what the gateway did, so
  # whatever is not in this format is not recorded anywhere.
  #
  # Every format offered in the console and in the service documentation -- CLF,
  # JSON, XML and CSV -- omits integrationErrorMessage. That is the field that
  # separates "API Gateway may not invoke the function", "the function returned
  # a shape the payload format does not allow" and "the integration ran past the
  # timeout": all three surface as a 500 and are otherwise identical in the log.
  # error.message and error.responseType cover the failures that happen before
  # an integration is reached, and authorizer.error covers the one that happens
  # instead of reaching it.
  default_access_log_format = jsonencode({
    requestId               = "$context.requestId"
    extendedRequestId       = "$context.extendedRequestId"
    requestTime             = "$context.requestTime"
    sourceIp                = "$context.identity.sourceIp"
    httpMethod              = "$context.httpMethod"
    path                    = "$context.path"
    routeKey                = "$context.routeKey"
    protocol                = "$context.protocol"
    status                  = "$context.status"
    responseLength          = "$context.responseLength"
    responseLatency         = "$context.responseLatency"
    integrationStatus       = "$context.integrationStatus"
    integrationLatency      = "$context.integrationLatency"
    integrationErrorMessage = "$context.integrationErrorMessage"
    errorMessage            = "$context.error.message"
    errorResponseType       = "$context.error.responseType"
    authorizerError         = "$context.authorizer.error"
  })

  access_log_format = coalesce(var.access_log_format, local.default_access_log_format)

  create_log_group      = var.access_log_group_name == null
  log_group_name        = coalesce(var.access_log_group_name, "/aws/apigateway/${var.name}/access")
  created_log_group_arn = local.create_log_group ? one(aws_cloudwatch_log_group.access[*].arn) : null

  # A route may set its own throttle; anything it leaves unset inherits the
  # stage default, so the effective value is resolved here rather than left to
  # be worked out from two places.
  #
  # Keyed by distinct route key rather than by the routes map, because a map
  # comprehension with a repeated key is an error Terraform raises while
  # evaluating locals -- which is before any precondition runs. Collapsing the
  # duplicates here is what keeps the duplicate-route-key guard below reachable
  # and its message readable.
  route_by_key = {
    for rk in distinct([for _, v in var.routes : v.route_key]) :
    rk => [for _, v in var.routes : v if v.route_key == rk][0]
  }

  route_settings = {
    for rk, v in local.route_by_key : rk => {
      throttling_burst_limit   = coalesce(v.throttling_burst_limit, var.default_throttling_burst_limit)
      throttling_rate_limit    = coalesce(v.throttling_rate_limit, var.default_throttling_rate_limit)
      detailed_metrics_enabled = v.detailed_metrics_enabled == null ? var.detailed_metrics_enabled : v.detailed_metrics_enabled
    }
  }

  # ---------------------------------------------------------------------------
  # Derivations used by the plan-time guards
  # ---------------------------------------------------------------------------

  # A route naming an integration that was never declared is a route with no
  # target. Collected rather than indexed so the failure is a readable message
  # instead of a missing-key error.
  routes_with_unknown_integration = {
    for k, v in var.routes : k => v.integration_key
    if !contains(keys(var.integrations), v.integration_key)
  }

  # API Gateway identifies a route by its route key, so two entries carrying the
  # same key are one route declared twice.
  duplicate_route_keys = [
    for rk in distinct([for _, v in var.routes : v.route_key]) : rk
    if length([for _, v in var.routes : v.route_key if v.route_key == rk]) > 1
  ]

  default_route_keys = [for k, v in var.routes : k if v.route_key == "$default"]

  authorized_default_route_keys = [
    for k, v in var.routes : k
    if v.route_key == "$default" && v.authorization_type != "NONE"
  ]

  # The documented escape from the preflight trap below: a route matching
  # OPTIONS on every path, requiring no authorization. It outranks $default,
  # because a route with a greedy variable is matched ahead of the catch-all.
  has_unauthenticated_options_catch_all = anytrue([
    for _, v in var.routes :
    can(regex("^OPTIONS /\\{[A-Za-z0-9._-]+\\+\\}$", v.route_key)) && v.authorization_type == "NONE"
  ])

  # A browser never carries credentials on a preflight request, so an authorizer
  # in front of OPTIONS rejects the preflight and the real request is never
  # sent. The API answers curl perfectly and fails from every browser.
  cors_preflight_is_authorized = (
    var.cors_configuration != null &&
    length(local.authorized_default_route_keys) > 0 &&
    !local.has_unauthenticated_options_catch_all
  )

  # ---------------------------------------------------------------------------
  # Invocation grants
  # ---------------------------------------------------------------------------

  lambda_routes = {
    for k, v in var.routes : k => merge(v, {
      function_arn = var.integrations[v.integration_key].uri
    })
    if contains(keys(var.integrations), v.integration_key) &&
    var.integrations[v.integration_key].type == "AWS_PROXY"
  }

  # A resource-based policy is written on the function, so a function owned by
  # another account or living in another region cannot be granted from here.
  # Those routes are reported rather than quietly left ungranted, because an
  # ungranted route fails with the same internal server error as everything else.
  grantable_lambda_routes = {
    for k, v in local.lambda_routes : k => v
    if var.manage_lambda_permissions &&
    split(":", v.function_arn)[4] == local.account_id &&
    split(":", v.function_arn)[3] == local.region
  }

  ungrantable_lambda_routes = {
    for k, v in local.lambda_routes : k => (
      !var.manage_lambda_permissions ? "invocation grants are managed outside this module" :
      split(":", v.function_arn)[4] != local.account_id ? "the function is owned by account ${split(":", v.function_arn)[4]}, and a resource policy can only be written by the owning account" :
      "the function is in ${split(":", v.function_arn)[3]}, and this API is in ${local.region}"
    )
    if !contains(keys(local.grantable_lambda_routes), k)
  }

  # The source ARN for the $default route has a different shape from every other
  # route: it carries no method and no path, because the route matches all of
  # them. Deriving it the usual way produces a grant that can never match, and
  # the symptom is the same internal server error as having no grant at all.
  #
  # For every other route the path is taken from the route key with its path
  # variables replaced by a wildcard, since a grant naming a literal {id} would
  # only ever match a request for that literal string.
  lambda_source_arns = {
    for k, v in local.grantable_lambda_routes : k => (
      v.route_key == "$default"
      ? "${aws_apigatewayv2_api.this.execution_arn}/${var.stage_name}/$default"
      : format(
        "%s/%s/%s/%s",
        aws_apigatewayv2_api.this.execution_arn,
        var.stage_name,
        split(" ", v.route_key)[0],
        trimprefix(replace(split(" ", v.route_key)[1], "/\\{[^}]*\\}/", "*"), "/")
      )
    )
  }

  # A statement id must be unique on the function and is capped at 100
  # characters, so two routes reaching one function need two ids. The readable
  # part is truncated and a digest of the full route key keeps it unique.
  lambda_statement_ids = {
    for k, v in local.grantable_lambda_routes : k => format(
      "%s-invoke-%s-%s",
      var.name,
      substr(replace(replace(v.route_key, "/[^A-Za-z0-9]+/", "-"), "/^-+|-+$/", ""), 0, 40),
      substr(sha1(v.route_key), 0, 8)
    )
  }
}

# ---------------------------------------------------------------------------
# Access log group
# ---------------------------------------------------------------------------

# The log group ARN is handed to the stage exactly as the provider exports it.
# The trimsuffix(..., ":*") that circulates for this field is obsolete twice
# over: the log group resource already trims the stream wildcard from the ARN it
# exports, and the stage resource trims any trailing :* it is given anyway.
resource "aws_cloudwatch_log_group" "access" {
  count = local.create_log_group ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.access_log_retention_days
  kms_key_id        = var.access_log_kms_key_arn

  tags = local.tags
}

# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "this" {
  name          = var.name
  description   = var.description
  protocol_type = "HTTP"

  disable_execute_api_endpoint = var.disable_default_endpoint

  dynamic "cors_configuration" {
    for_each = var.cors_configuration == null ? toset([]) : toset(["enabled"])

    content {
      allow_origins     = var.cors_configuration.allow_origins
      allow_methods     = var.cors_configuration.allow_methods
      allow_headers     = var.cors_configuration.allow_headers
      expose_headers    = var.cors_configuration.expose_headers
      allow_credentials = var.cors_configuration.allow_credentials
      max_age           = var.cors_configuration.max_age
    }
  }

  tags = local.tags
}

# These three describe the route table, so they are checked on a node of their
# own rather than on the API.
#
# A precondition is evaluated as part of the resource that carries it, which
# means it also becomes part of that resource's dependencies. Carried on the
# API, a check that reads var.routes made the API's own identifier depend on
# the route table -- and an identifier that depends on routes cannot be used to
# build anything a route then refers to. Authorizers are exactly that: they are
# created against the API id, and routes name the authorizer that decides them.
# The plan-time failure is unchanged, because all three read inputs that are
# known before anything is created.
resource "terraform_data" "route_table_guards" {
  lifecycle {
    precondition {
      condition     = length(local.routes_with_unknown_integration) == 0
      error_message = "These routes name an integration that is not declared: ${jsonencode(local.routes_with_unknown_integration)}."
    }

    precondition {
      condition     = length(local.duplicate_route_keys) == 0
      error_message = "A route key identifies one route, and these are declared more than once: ${join(", ", local.duplicate_route_keys)}."
    }

    precondition {
      condition     = !local.cors_preflight_is_authorized
      error_message = "CORS is configured and the $default route requires authorization, so it also catches the browser's preflight OPTIONS request. A browser sends no credentials on a preflight, so every cross-origin call fails while the API answers a direct client normally. Add a route with key \"OPTIONS /{proxy+}\" and authorization_type NONE, which outranks $default."
    }
  }
}

# ---------------------------------------------------------------------------
# Integrations
# ---------------------------------------------------------------------------

# payload_format_version is always sent, and always from this module's own
# default rather than the provider's. The provider defaults it to 1.0 while the
# console creates Lambda integrations at 2.0, so an API rebuilt in Terraform
# against a function written for a console-created one changes the event shape
# underneath it: the request context moves, rawPath is not populated, and the
# handler fails on input it used to be given.
resource "aws_apigatewayv2_integration" "this" {
  for_each = var.integrations

  api_id           = aws_apigatewayv2_api.this.id
  description      = each.value.description
  integration_type = each.value.type
  integration_uri  = each.value.uri

  integration_method     = each.value.integration_method
  payload_format_version = each.value.payload_format_version
  timeout_milliseconds   = each.value.timeout_milliseconds

  connection_type = each.value.connection_type
  connection_id   = each.value.vpc_link_id

  request_parameters = each.value.request_parameters
}

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_route" "this" {
  for_each = var.routes

  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.value.route_key
  target    = "integrations/${aws_apigatewayv2_integration.this[each.value.integration_key].id}"

  authorization_type   = each.value.authorization_type
  authorizer_id        = each.value.authorizer_id
  authorization_scopes = length(each.value.authorization_scopes) > 0 ? each.value.authorization_scopes : null
}

# ---------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = var.stage_name
  auto_deploy = var.stage_auto_deploy

  # Only meaningful when auto_deploy is off, and the precondition below refuses
  # that combination unless a deployment was supplied.
  deployment_id = var.stage_auto_deploy ? null : var.stage_deployment_id

  access_log_settings {
    destination_arn = local.create_log_group ? local.created_log_group_arn : "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${var.access_log_group_name}"
    format          = local.access_log_format
  }

  default_route_settings {
    throttling_burst_limit   = var.default_throttling_burst_limit
    throttling_rate_limit    = var.default_throttling_rate_limit
    detailed_metrics_enabled = var.detailed_metrics_enabled
  }

  dynamic "route_settings" {
    for_each = local.route_settings

    content {
      route_key                = route_settings.key
      throttling_burst_limit   = route_settings.value.throttling_burst_limit
      throttling_rate_limit    = route_settings.value.throttling_rate_limit
      detailed_metrics_enabled = route_settings.value.detailed_metrics_enabled
    }
  }

  tags = local.tags

  lifecycle {
    # A stage with neither automatic deployment nor a deployment identifier is
    # the quietest failure this configuration can produce: the API, its routes
    # and its integrations are all created and correct, and every request is
    # answered by whatever was last deployed -- which, on a new API, is nothing,
    # so a route visible in the console returns {"message":"Not Found"}.
    precondition {
      condition     = var.stage_auto_deploy || var.stage_deployment_id != null
      error_message = "stage_auto_deploy is off and no stage_deployment_id was supplied, so changes to routes and integrations would be applied to the API and never served."
    }
  }
}

# ---------------------------------------------------------------------------
# Invocation grants
# ---------------------------------------------------------------------------

# Creating an integration in the console attaches this grant for you; creating
# one through the API, and therefore through Terraform, does not. Without it the
# route answers {"message":"Internal Server Error"} and says nothing further,
# which is the single most likely first failure of an API built this way.
resource "aws_lambda_permission" "invoke" {
  for_each = local.grantable_lambda_routes

  statement_id  = local.lambda_statement_ids[each.key]
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = local.lambda_source_arns[each.key]
}
