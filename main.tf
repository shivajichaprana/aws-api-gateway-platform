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
  routes       = var.api_routes

  cors_configuration       = var.api_cors_configuration
  stage_name               = var.api_stage_name
  disable_default_endpoint = var.api_disable_default_endpoint

  access_log_retention_days = var.access_log_retention_days
  access_log_kms_key_arn    = local.key_arn

  tags = var.default_tags
}
