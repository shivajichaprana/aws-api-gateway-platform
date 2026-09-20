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

# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

variable "api_name" {
  description = "Name of the HTTP API this configuration deploys."
  type        = string
  default     = "platform-http-api"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,26}[a-z0-9]$", var.api_name))
    error_message = "api_name must be 3-28 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "api_description" {
  description = "Description recorded on the API."
  type        = string
  default     = "HTTP API front door"
}

variable "api_integrations" {
  description = <<-EOT
    Backends the API can reach. Empty by default: every integration names a
    function or an endpoint owned outside this configuration, so a placeholder
    default would deploy an API pointing at an account that does not exist.
    The repository README carries a worked example.
  EOT
  type = map(object({
    type                   = string
    uri                    = string
    integration_method     = optional(string)
    payload_format_version = optional(string, "2.0")
    timeout_milliseconds   = optional(number, 30000)
    connection_type        = optional(string, "INTERNET")
    vpc_link_id            = optional(string)
    request_parameters     = optional(map(string), {})
    description            = optional(string)
  }))
  default = {}
}

variable "api_routes" {
  description = "Routes exposed by the API. Empty by default, for the same reason as api_integrations."
  type = map(object({
    route_key                = string
    integration_key          = string
    authorization_type       = optional(string, "NONE")
    authorizer_id            = optional(string)
    authorization_scopes     = optional(list(string), [])
    throttling_burst_limit   = optional(number)
    throttling_rate_limit    = optional(number)
    detailed_metrics_enabled = optional(bool)
  }))
  default = {}
}

variable "api_cors_configuration" {
  description = "Cross-origin configuration for the API. Null when the API is not called from a browser."
  type = object({
    allow_origins     = list(string)
    allow_methods     = optional(list(string), ["GET", "HEAD", "OPTIONS"])
    allow_headers     = optional(list(string), ["authorization", "content-type"])
    expose_headers    = optional(list(string), [])
    allow_credentials = optional(bool, false)
    max_age           = optional(number, 300)
  })
  default = null
}

variable "api_stage_name" {
  description = "Stage serving the API."
  type        = string
  default     = "$default"
}

variable "api_disable_default_endpoint" {
  description = "Refuse requests to the generated execute-api endpoint. Turn this on once a custom domain fronts the API."
  type        = bool
  default     = false
}
