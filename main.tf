data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # The access log group's name is DERIVED here rather than read back from the
  # module, because the key policy has to admit the group and the group cannot
  # be created until the key exists. Predicting the name from an input breaks
  # that circle: the key depends only on variables, and the group depends on the
  # key. The module derives the same name from the same input, and the two
  # derivations are checked against each other rather than kept in step by hand.
  access_log_group_name = "/aws/apigateway/${var.api_name}/access"
  access_log_group_arn  = "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:${local.access_log_group_name}"

  create_key = var.create_kms_key && var.access_log_kms_key_arn == null
  key_arn    = var.access_log_kms_key_arn != null ? var.access_log_kms_key_arn : one(aws_kms_key.access_logs[*].arn)

  # A route that names no authorizer keeps authorizer_id null; one that names a
  # key that was never declared resolves to null too, which the API module's
  # own validation rejects by name rather than failing on a missing map entry.
  routes_with_authorizers = {
    for key, route in var.api_routes :
    key => {
      route_key            = route.route_key
      integration_key      = route.integration_key
      authorization_type   = route.authorization_type
      authorization_scopes = route.authorization_scopes

      authorizer_id = (
        route.authorizer_key == null
        ? null
        : lookup(module.authorizers.authorizer_ids, route.authorizer_key, null)
      )

      throttling_burst_limit   = route.throttling_burst_limit
      throttling_rate_limit    = route.throttling_rate_limit
      detailed_metrics_enabled = route.detailed_metrics_enabled
    }
  }

  routes_naming_an_undeclared_authorizer = sort([
    for key, route in var.api_routes : key
    if route.authorizer_key != null && !contains(
      concat(keys(var.api_jwt_authorizers), keys(var.api_lambda_authorizers)),
      route.authorizer_key
    )
  ])
}

# ---------------------------------------------------------------------------
# Access log encryption
# ---------------------------------------------------------------------------

# CloudWatch Logs uses the key itself, as a service principal, rather than
# assuming a role this configuration controls. A group pointed at a key whose
# policy does not admit the service is refused at creation, so the grant is part
# of the key rather than something to remember afterwards. It is narrowed by the
# encryption context to this one log group, which is the only scoping the
# service offers on this call.
data "aws_iam_policy_document" "access_logs_key" {
  count = local.create_key ? 1 : 0

  statement {
    sid       = "AllowAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowCloudWatchLogsToUseTheKey"
    effect = "Allow"

    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [local.access_log_group_arn]
    }
  }
}

resource "aws_kms_key" "access_logs" {
  count = local.create_key ? 1 : 0

  description             = "Encrypts API Gateway access logs for ${var.api_name}"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_days
  policy                  = one(data.aws_iam_policy_document.access_logs_key[*].json)
}

resource "aws_kms_alias" "access_logs" {
  count = local.create_key ? 1 : 0

  name          = "alias/${var.name_prefix}-api-access-logs"
  target_key_id = one(aws_kms_key.access_logs[*].key_id)
}

# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

module "http_api" {
  source = "./modules/http-api"

  name        = var.api_name
  description = var.api_description

  integrations = var.api_integrations

  # Routes name an authorizer by the key it was declared under, and the id is
  # resolved here. Writing an id into a route by hand means copying a value
  # that only exists after an apply, which is how a route ends up pointing at
  # an authorizer that was replaced.
  routes = local.routes_with_authorizers

  cors_configuration       = var.api_cors_configuration
  stage_name               = var.api_stage_name
  disable_default_endpoint = var.api_disable_default_endpoint

  access_log_retention_days = var.access_log_retention_days
  access_log_kms_key_arn    = local.key_arn

  tags = var.default_tags
}

# ---------------------------------------------------------------------------
# Authorizers
# ---------------------------------------------------------------------------

# The two module calls reference each other's values, and that is fine as long
# as one property holds: the API id must not depend on the route table.
# Terraform follows individual values rather than whole modules, so the order it
# derives is api -> authorizers -> routes.
#
# The property is not automatic. A precondition becomes part of the
# dependencies of whatever resource carries it, so the route-table checks that
# used to sit on the API resource made the API id depend on var.routes, which
# closes this into a cycle. They live on a node of their own in the API module
# for that reason.
#
# It stops being fine the moment depends_on is added to either call. depends_on
# on a module is not a hint about one value; it makes everything inside that
# module wait for everything in the target, which closes this into a cycle
# Terraform refuses to plan. The ordering is already stated by the values that
# flow between the two calls, so there is nothing left for depends_on to add.
module "authorizers" {
  source = "./modules/authorizers"

  api_id            = module.http_api.api_id
  api_execution_arn = module.http_api.api_execution_arn
  name_prefix       = var.api_name

  jwt_authorizers    = var.api_jwt_authorizers
  lambda_authorizers = var.api_lambda_authorizers

  tags = var.default_tags
}

# A route naming an authorizer that was never declared would otherwise reach the
# API module as a null id, which it reports as a missing authorizer rather than
# as a name that does not exist. Naming the route and the key is the difference
# between a five-minute fix and a search.
resource "terraform_data" "route_authorizer_names" {
  lifecycle {
    precondition {
      condition = length(local.routes_naming_an_undeclared_authorizer) == 0
      error_message = format(
        "These routes name an authorizer that is not declared in api_jwt_authorizers or api_lambda_authorizers: %s.",
        join(", ", local.routes_naming_an_undeclared_authorizer)
      )
    }
  }
}
