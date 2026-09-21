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
  description = <<-EOT
    Routes exposed by the API. Empty by default, for the same reason as
    api_integrations.

    A protected route names its authorizer by the key it was declared under in
    api_jwt_authorizers or api_lambda_authorizers, not by identifier: an
    authorizer id only exists after an apply, so writing one here means copying
    a value that changes whenever the authorizer is replaced.

    On a JWT route, authorization_scopes are matched as ANY-of. A route listing
    three scopes admits a token holding one of them. To require all of them,
    point the route at a Lambda authorizer declared with scope_enforcement.
  EOT
  type = map(object({
    route_key                = string
    integration_key          = string
    authorization_type       = optional(string, "NONE")
    authorizer_key           = optional(string)
    authorization_scopes     = optional(list(string), [])
    throttling_burst_limit   = optional(number)
    throttling_rate_limit    = optional(number)
    detailed_metrics_enabled = optional(bool)
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, v in var.api_routes :
      v.authorizer_key != null if contains(["JWT", "CUSTOM"], v.authorization_type)
    ])
    error_message = "A JWT or CUSTOM route must name the authorizer_key that decides it."
  }

  validation {
    condition = alltrue([
      for _, v in var.api_routes :
      v.authorizer_key == null if contains(["NONE", "AWS_IAM"], v.authorization_type)
    ])
    error_message = "authorizer_key applies only to a JWT or CUSTOM route. AWS_IAM is decided by SigV4 and an IAM policy, and NONE is decided by nothing."
  }
}

# ---------------------------------------------------------------------------
# Authorizers
# ---------------------------------------------------------------------------

variable "api_jwt_authorizers" {
  description = <<-EOT
    Authorizers that verify a JWT inside API Gateway, keyed by a name routes
    refer to. Each names either an issuer or a Cognito user pool.

    See modules/authorizers for the full contract, including why a scoped route
    decided by one of these is satisfied by any one of its scopes.
  EOT
  type = map(object({
    audience             = list(string)
    issuer               = optional(string)
    cognito_user_pool_id = optional(string)
    identity_source      = optional(string, "$request.header.Authorization")
  }))
  default = {}
}

variable "api_lambda_authorizers" {
  description = <<-EOT
    Authorizers that call a function to decide a request, keyed by a name routes
    refer to. Each either names an existing function or declares
    scope_enforcement, which deploys the bundled authorizer and requires every
    scope a route asks for rather than any one of them.
  EOT
  type = map(object({
    function_arn            = optional(string)
    identity_sources        = optional(list(string), ["$request.header.Authorization"])
    result_ttl_in_seconds   = optional(number, 0)
    payload_format_version  = optional(string, "2.0")
    enable_simple_responses = optional(bool, true)
    scope_enforcement = optional(object({
      issuer                = string
      audience              = list(string)
      required_scopes       = optional(map(list(string)), {})
      unlisted_route_action = optional(string, "deny")
      jwks_cache_seconds    = optional(number, 600)
      clock_skew_seconds    = optional(number, 60)
      memory_size           = optional(number, 256)
      timeout_seconds       = optional(number, 5)
      log_retention_days    = optional(number, 90)
      log_kms_key_arn       = optional(string)
    }))
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
