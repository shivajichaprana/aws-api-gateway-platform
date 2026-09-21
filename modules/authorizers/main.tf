data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  region    = data.aws_region.current.name
  partition = data.aws_partition.current.partition

  # A Cognito user pool id begins with the region the pool lives in, so the
  # issuer is derived from the pool rather than assembled from a second input.
  # Two inputs that have to agree eventually disagree, and a mismatched issuer
  # refuses every token with a message about the token rather than about the
  # configuration.
  jwt_issuers = {
    for key, cfg in var.jwt_authorizers :
    key => (
      cfg.issuer != null
      ? cfg.issuer
      : "https://cognito-idp.${split("_", cfg.cognito_user_pool_id)[0]}.amazonaws.com/${cfg.cognito_user_pool_id}"
    )
  }

  jwt_authorizer_names    = { for key, _ in var.jwt_authorizers : key => "${var.name_prefix}-${key}" }
  lambda_authorizer_names = { for key, _ in var.lambda_authorizers : key => "${var.name_prefix}-${key}" }

  # Entries whose function this module builds, and entries that point at one
  # somebody else owns. Everything downstream is driven off these two, so the
  # split is made once.
  enforcing = {
    for key, cfg in var.lambda_authorizers :
    key => cfg.scope_enforcement if cfg.scope_enforcement != null
  }

  # The invoke URI is a path-style ARN rather than the function ARN. Passing the
  # function ARN straight through is accepted by the provider and rejected by
  # API Gateway at create time.
  authorizer_function_arns = {
    for key, cfg in var.lambda_authorizers :
    key => (
      cfg.function_arn != null
      ? cfg.function_arn
      : aws_lambda_function.scope_enforcer[key].arn
    )
  }

  authorizer_uris = {
    for key, arn in local.authorizer_function_arns :
    key => "arn:${local.partition}:apigateway:${local.region}:lambda:path/2015-03-31/functions/${arn}/invocations"
  }

  # A granted invocation is scoped to the authorizer, and an authorizer's
  # execute-api ARN carries no stage, no method and no path -- unlike a route's.
  # Deriving it the way a route grant is derived produces a grant that can never
  # match, and a grant that never matches fails exactly like no grant at all.
  authorizer_source_arns = {
    for key, authorizer in aws_apigatewayv2_authorizer.lambda :
    key => "${var.api_execution_arn}/authorizers/${authorizer.id}"
  }

  # Reported rather than assumed: a cached decision outlives the token that
  # produced it, up to the TTL.
  cached_authorizers = {
    for key, cfg in var.lambda_authorizers :
    key => cfg.result_ttl_in_seconds if cfg.result_ttl_in_seconds > 0
  }

  jwt_authorizer_id_map    = { for key, authorizer in aws_apigatewayv2_authorizer.jwt : key => authorizer.id }
  lambda_authorizer_id_map = { for key, authorizer in aws_apigatewayv2_authorizer.lambda : key => authorizer.id }

  # concat with an empty object first: with no enforcing authorizers the list
  # comprehension is empty, and expanding an empty list into merge leaves it
  # with no arguments at all.
  scope_enforced_routes = merge(concat([{}], [
    for key, cfg in local.enforcing : {
      for route_key, scopes in cfg.required_scopes :
      "${key}/${route_key}" => scopes
    }
  ])...)
}

# ---------------------------------------------------------------------------
# JWT authorizers
# ---------------------------------------------------------------------------

# API Gateway verifies the signature and the standard claims itself, against
# keys it fetches from the issuer. There is no function in the path and nothing
# is cached, so a token is re-checked on every request and its expiry is the
# moment access ends. That is the difference from the Lambda authorizer below,
# where a cached decision survives the token.
resource "aws_apigatewayv2_authorizer" "jwt" {
  for_each = var.jwt_authorizers

  api_id           = var.api_id
  authorizer_type  = "JWT"
  name             = local.jwt_authorizer_names[each.key]
  identity_sources = [each.value.identity_source]

  jwt_configuration {
    audience = each.value.audience
    issuer   = local.jwt_issuers[each.key]
  }

  lifecycle {
    precondition {
      condition     = length(local.jwt_authorizer_names[each.key]) <= 128
      error_message = "Authorizer name \"${local.jwt_authorizer_names[each.key]}\" is longer than the 128 characters API Gateway accepts. Shorten name_prefix or the authorizer key."
    }
  }
}

# ---------------------------------------------------------------------------
# Bundled scope-enforcing function
# ---------------------------------------------------------------------------

data "archive_file" "scope_enforcer" {
  for_each = local.enforcing

  type = "zip"
  # Packaged from inside the module, so a caller consuming this module by
  # reference gets the function along with the configuration that deploys it.
  source_dir  = "${path.module}/function"
  output_path = "${path.module}/.terraform-build/${var.name_prefix}-${each.key}-authorizer.zip"
}

data "aws_iam_policy_document" "scope_enforcer_assume" {
  for_each = local.enforcing

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scope_enforcer" {
  for_each = local.enforcing

  name               = "${var.name_prefix}-${each.key}-authorizer"
  assume_role_policy = data.aws_iam_policy_document.scope_enforcer_assume[each.key].json
  tags               = var.tags

  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-${each.key}-authorizer") <= 64
      error_message = "Derived role name \"${var.name_prefix}-${each.key}-authorizer\" is longer than the 64 characters IAM accepts. Shorten name_prefix or the authorizer key."
    }
  }
}

# The function reads a public key set over the internet and decides. It reads
# nothing in this account, so it is granted nothing in this account beyond the
# ability to write its own logs.
data "aws_iam_policy_document" "scope_enforcer_logs" {
  for_each = local.enforcing

  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.scope_enforcer[each.key].arn}:*"]
  }
}

resource "aws_iam_role_policy" "scope_enforcer_logs" {
  for_each = local.enforcing

  name   = "logs"
  role   = aws_iam_role.scope_enforcer[each.key].id
  policy = data.aws_iam_policy_document.scope_enforcer_logs[each.key].json
}

resource "aws_cloudwatch_log_group" "scope_enforcer" {
  for_each = local.enforcing

  name              = "/aws/lambda/${var.name_prefix}-${each.key}-authorizer"
  retention_in_days = each.value.log_retention_days
  kms_key_id        = each.value.log_kms_key_arn
  tags              = var.tags
}

resource "aws_lambda_function" "scope_enforcer" {
  for_each = local.enforcing

  function_name = "${var.name_prefix}-${each.key}-authorizer"
  role          = aws_iam_role.scope_enforcer[each.key].arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]

  filename         = data.archive_file.scope_enforcer[each.key].output_path
  source_code_hash = data.archive_file.scope_enforcer[each.key].output_base64sha256

  memory_size = each.value.memory_size
  timeout     = each.value.timeout_seconds

  environment {
    variables = {
      ISSUER   = each.value.issuer
      AUDIENCE = jsonencode(each.value.audience)

      # Keyed by route key, which is the exact string API Gateway puts in
      # $context.routeKey, so the lookup needs no parsing and cannot drift from
      # the route it is meant to describe.
      REQUIRED_SCOPES       = jsonencode(each.value.required_scopes)
      UNLISTED_ROUTE_ACTION = each.value.unlisted_route_action

      JWKS_CACHE_SECONDS = tostring(each.value.jwks_cache_seconds)
      CLOCK_SKEW_SECONDS = tostring(each.value.clock_skew_seconds)
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = var.tags

  # The group is created here rather than left to the function's first
  # invocation, so retention and encryption apply to the first log line rather
  # than to whatever is written after somebody notices.
  depends_on = [
    aws_iam_role_policy.scope_enforcer_logs,
    aws_cloudwatch_log_group.scope_enforcer,
  ]
}

# ---------------------------------------------------------------------------
# Lambda authorizers
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_authorizer" "lambda" {
  for_each = var.lambda_authorizers

  api_id          = var.api_id
  authorizer_type = "REQUEST"
  name            = local.lambda_authorizer_names[each.key]
  authorizer_uri  = local.authorizer_uris[each.key]

  identity_sources                  = each.value.identity_sources
  authorizer_payload_format_version = each.value.payload_format_version
  enable_simple_responses           = each.value.enable_simple_responses

  # Always stated. Left out, the provider fills this in with 300 on its own for
  # an HTTP REQUEST authorizer -- and which configurations it does that for
  # changed within the version range this repository pins, so the same file
  # produces a cached authorizer on one resolved provider and an uncached one on
  # another. Stating it makes the answer the same either way.
  authorizer_result_ttl_in_seconds = each.value.result_ttl_in_seconds

  lifecycle {
    precondition {
      condition     = length(local.lambda_authorizer_names[each.key]) <= 128
      error_message = "Authorizer name \"${local.lambda_authorizer_names[each.key]}\" is longer than the 128 characters API Gateway accepts. Shorten name_prefix or the authorizer key."
    }
  }
}

resource "aws_lambda_permission" "authorizer" {
  for_each = var.manage_lambda_permissions ? var.lambda_authorizers : {}

  statement_id  = "${var.name_prefix}-${each.key}-authorizer"
  action        = "lambda:InvokeFunction"
  function_name = local.authorizer_function_arns[each.key]
  principal     = "apigateway.amazonaws.com"
  source_arn    = local.authorizer_source_arns[each.key]
}

# ---------------------------------------------------------------------------
# Guards that span both maps
# ---------------------------------------------------------------------------

# A route names one authorizer id, so the two maps are merged for the caller to
# look up. Merging silently drops a duplicate key, and the one that survives
# decides requests the other was written for -- so a collision is refused here
# rather than resolved by whichever merge argument came last. A variable
# validation cannot see a second variable on every Terraform release this
# module supports, which is why the check lives on a resource.
resource "terraform_data" "authorizer_key_collisions" {
  lifecycle {
    precondition {
      condition = length(setintersection(keys(var.jwt_authorizers), keys(var.lambda_authorizers))) == 0
      error_message = format(
        "These names are used by both a JWT and a Lambda authorizer: %s. Authorizer names are merged into one lookup for routes to refer to, so each has to be unique across both.",
        join(", ", sort(setintersection(keys(var.jwt_authorizers), keys(var.lambda_authorizers))))
      )
    }
  }
}
