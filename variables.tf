variable "aws_region" {
  description = "Region hosting the API, its stage and its access log group."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a region code such as us-east-1 or eu-west-2."
  }
}

variable "name_prefix" {
  description = <<-EOT
    Prefix for every name this configuration derives. Kept short because the
    tightest downstream limit is the Lambda permission statement id at 100
    characters, which also has to carry a route key.
  EOT
  type        = string
  default     = "api-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,26}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-28 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "default_tags" {
  description = "Tags applied to every resource the provider creates."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Component = "api-platform"
  }
}

variable "access_log_retention_days" {
  description = "Retention for the API access log group. Access logs are the only diagnostic surface an HTTP API has, so an unset retention keeps them for ever and a short one discards the evidence of an incident before anyone reads it."
  type        = number
  default     = 90

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.access_log_retention_days
    )
    error_message = "access_log_retention_days must be one of the retention periods CloudWatch Logs accepts."
  }
}

variable "create_kms_key" {
  description = "Create a customer-managed key for the access log group. Set false to supply access_log_kms_key_arn, or to leave the group on CloudWatch's default encryption."
  type        = bool
  default     = true
}

variable "access_log_kms_key_arn" {
  description = "Existing customer-managed key for the access log group. Its policy must already admit the CloudWatch Logs service principal in this region, or creating the group fails."
  type        = string
  default     = null

  validation {
    condition     = var.access_log_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.access_log_kms_key_arn))
    error_message = "access_log_kms_key_arn must be a KMS key ARN (an alias ARN is not accepted by the log group)."
  }
}

variable "kms_deletion_window_days" {
  description = "Waiting period before a scheduled key deletion completes."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}
