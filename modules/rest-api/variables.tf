variable "name" {
  description = "Name of the REST API. Every name this module derives is built from it, and the longest of those is a usage plan name at name plus 6 characters against a 1024-character service limit, so the bound here is readability rather than truncation."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.name))
    error_message = "name must be 3-40 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "description" {
  description = "Description recorded on the API."
  type        = string
  default     = "REST API with metered access"
}

variable "endpoint_type" {
  description = <<-EOT
    Where the API is served from.

    REGIONAL answers in this region. EDGE puts an API Gateway-owned CloudFront
    distribution in front of it, which is not a distribution this account can
    attach anything to -- a web ACL still associates with the stage, and it
    still has to be a regional one. PRIVATE is reachable only through an
    interface endpoint and needs a resource policy naming it.
  EOT
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "EDGE", "PRIVATE"], var.endpoint_type)
    error_message = "endpoint_type must be REGIONAL, EDGE or PRIVATE."
  }
}

variable "stage_name" {
  description = "Stage serving the API. A REST API stage name appears in the invoke URL, unlike an HTTP API's $default stage."
  type        = string
  default     = "live"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,128}$", var.stage_name))
    error_message = "stage_name must be 1-128 characters of letters, digits, underscores and hyphens."
  }
}

variable "methods" {
  description = <<-EOT
    Methods the API exposes, keyed by a name used for the resources this module
    derives. Empty by default: every integration names a function or an
    endpoint owned outside this module.

    path is the full resource path with a leading slash, such as /orders/{id}.
    The root path is "/". Path variables are written in braces and become part
    of the resource tree, so /orders/{id} and /orders/{orderId} are two
    different resources and API Gateway refuses the pair as a conflict.

    api_key_required is deliberately nullable rather than defaulted to false.
    Left unset it follows default_api_key_required, which is itself derived
    from whether any usage plan exists -- because a method that does not
    require a key is not metered by any plan, and nothing anywhere reports
    that. The key is what identifies the caller; without it a usage plan has
    nobody to meter.
  EOT
  type = map(object({
    path                 = string
    http_method          = string
    authorization        = optional(string, "NONE")
    authorizer_id        = optional(string)
    authorization_scopes = optional(list(string), [])
    api_key_required     = optional(bool)
    request_parameters   = optional(map(bool), {})
    integration = object({
      type                    = string
      uri                     = optional(string)
      integration_http_method = optional(string, "POST")
      connection_type         = optional(string, "INTERNET")
      connection_id           = optional(string)
      timeout_milliseconds    = optional(number, 29000)
      request_parameters      = optional(map(string), {})
      request_templates       = optional(map(string), {})
    })
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, _ in var.methods : can(regex("^[a-z][a-z0-9-]{0,48}[a-z0-9]$", k))
    ])
    error_message = "Each methods key must be 2-50 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods : can(regex("^/([A-Za-z0-9._{}+-]+(/[A-Za-z0-9._{}+-]+)*)?$", m.path))
    ])
    error_message = "Each method path must start with / and contain path segments of letters, digits, dots, underscores, hyphens, plus signs or a {variable}."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      contains(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "ANY"], m.http_method)
    ])
    error_message = "Each http_method must be one of GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS or ANY."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      contains(["NONE", "AWS_IAM", "CUSTOM", "COGNITO_USER_POOLS"], m.authorization)
    ])
    error_message = "Each authorization must be NONE, AWS_IAM, CUSTOM or COGNITO_USER_POOLS."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      m.authorizer_id != null if contains(["CUSTOM", "COGNITO_USER_POOLS"], m.authorization)
    ])
    error_message = "A CUSTOM or COGNITO_USER_POOLS method must name the authorizer_id that decides it."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      length(m.authorization_scopes) == 0 if m.authorization != "COGNITO_USER_POOLS"
    ])
    error_message = "authorization_scopes are read only on a COGNITO_USER_POOLS method. On any other method they are accepted and enforce nothing."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      contains(["AWS", "AWS_PROXY", "HTTP", "HTTP_PROXY", "MOCK"], m.integration.type)
    ])
    error_message = "Each integration type must be AWS, AWS_PROXY, HTTP, HTTP_PROXY or MOCK."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      m.integration.uri != null if m.integration.type != "MOCK"
    ])
    error_message = "Every integration except MOCK needs a uri. A MOCK integration answers from a response template and reaches nothing."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      m.integration.uri == null if m.integration.type == "MOCK"
    ])
    error_message = "A MOCK integration takes no uri."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      m.integration.timeout_milliseconds >= 50 && m.integration.timeout_milliseconds <= 29000
    ])
    error_message = "integration timeout_milliseconds must be between 50 and 29000. A REST API integration stops at 29 seconds, which is one second below the HTTP API ceiling in this repository -- a backend moved between the two keeps working and a backend written to the wrong ceiling returns 504 while its work continues and is billed."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      contains(["INTERNET", "VPC_LINK"], m.integration.connection_type)
    ])
    error_message = "integration connection_type must be INTERNET or VPC_LINK."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      m.integration.connection_id != null if m.integration.connection_type == "VPC_LINK"
    ])
    error_message = "A VPC_LINK integration must name the connection_id of the link it goes through."
  }

  validation {
    condition = alltrue([
      for _, m in var.methods :
      m.integration.connection_id == null if m.integration.connection_type == "INTERNET"
    ])
    error_message = "connection_id applies only to a VPC_LINK integration."
  }
}

variable "default_api_key_required" {
  description = <<-EOT
    Whether a method that does not state otherwise requires an API key.

    Null means: required when this module creates at least one usage plan, and
    not otherwise. That is the useful default because the alternative fails
    without saying so -- keys exist, plans exist, keys are attached to plans,
    every page in the console looks configured, and every request is served
    without a key and counted against nothing.
  EOT
  type        = bool
  default     = null
}

variable "api_key_source" {
  description = <<-EOT
    Where API Gateway reads the key from. HEADER takes the x-api-key header.
    AUTHORIZER takes whatever the request authorizer returned as its usage
    identifier and ignores the header entirely, so a client sending a perfectly
    good key is metered against nothing.
  EOT
  type        = string
  default     = "HEADER"

  validation {
    condition     = contains(["HEADER", "AUTHORIZER"], var.api_key_source)
    error_message = "api_key_source must be HEADER or AUTHORIZER."
  }
}

# ---------------------------------------------------------------------------
# Throttling
# ---------------------------------------------------------------------------

variable "stage_throttle" {
  description = <<-EOT
    Throttle applied to every method in the stage, as an aggregate across all
    callers. Null leaves the stage at the account limit.

    This is the only ceiling on the API as a whole. A usage plan's limits are
    per API key, so ten keys on a plan rated at 100 requests a second are up to
    1000 requests a second arriving at the stage, and adding an eleventh client
    raises the ceiling again without anything being reconfigured.
  EOT
  type = object({
    rate_limit  = number
    burst_limit = number
  })
  default = null

  validation {
    condition     = var.stage_throttle == null || try(var.stage_throttle.rate_limit > 0 && var.stage_throttle.burst_limit > 0, false)
    error_message = "stage_throttle rate_limit and burst_limit must both be greater than zero. API Gateway treats zero as unset rather than as a refusal."
  }
}

variable "method_throttles" {
  description = <<-EOT
    Per-method throttle overrides for the stage, keyed by the same key used in
    methods. These are aggregates too, not per caller.

    The method is named by key rather than by path. API Gateway identifies a
    method in a throttle setting by a string built from its resource path and
    its verb, and it accepts a string that matches no method in the API without
    complaint -- the setting is stored, applies to nothing, and reads as though
    it applies to something.
  EOT
  type = map(object({
    rate_limit  = number
    burst_limit = number
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, t in var.method_throttles : t.rate_limit > 0 && t.burst_limit > 0
    ])
    error_message = "Each method throttle rate_limit and burst_limit must be greater than zero."
  }
}

# ---------------------------------------------------------------------------
# Usage plans and keys
# ---------------------------------------------------------------------------

variable "api_keys" {
  description = <<-EOT
    API keys this module creates, keyed by a name usage plans refer to.

    A key value is generated by API Gateway and is then held in Terraform
    state, because the provider reads it back. There is no configuration that
    avoids that, so the state for this module is as sensitive as the keys in
    it. Supplying a value is deliberately not offered: it would put the
    credential in the configuration as well.

    A key is an identifier, not a credential check. API Gateway confirms the
    key exists and is attached to a plan covering the stage; it authorizes
    nothing. Pair it with an authorizer or IAM when the question is who may
    call, and use it for the question of how much.
  EOT
  type = map(object({
    description = optional(string)
    enabled     = optional(bool, true)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, _ in var.api_keys : can(regex("^[a-z][a-z0-9-]{0,48}[a-z0-9]$", k))
    ])
    error_message = "Each api_keys key must be 2-50 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "usage_plans" {
  description = <<-EOT
    Usage plans, keyed by a name used for the plan and reported in the outputs.

    throttle is per API key, and so is quota. Both are described by AWS as
    best-effort targets rather than guaranteed ceilings, so a plan is a way of
    telling clients apart and shaping their traffic, not a limit to be relied
    on for correctness.

    method_throttles inside a plan are per key as well, and each names a method
    by its key in methods, for the same reason the stage-level ones do.
  EOT
  type = map(object({
    description = optional(string)
    api_keys    = optional(list(string), [])
    throttle = optional(object({
      rate_limit  = number
      burst_limit = number
    }))
    quota = optional(object({
      limit  = number
      period = string
      offset = optional(number, 0)
    }))
    method_throttles = optional(map(object({
      rate_limit  = number
      burst_limit = number
    })), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, _ in var.usage_plans : can(regex("^[a-z][a-z0-9-]{0,48}[a-z0-9]$", k))
    ])
    error_message = "Each usage_plans key must be 2-50 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }

  validation {
    condition = alltrue([
      for _, p in var.usage_plans : p.throttle == null || try(p.throttle.rate_limit > 0 && p.throttle.burst_limit > 0, false)
    ])
    error_message = "A usage plan throttle must set rate_limit and burst_limit above zero."
  }

  validation {
    condition = alltrue([
      for _, p in var.usage_plans : p.quota == null || try(contains(["DAY", "WEEK", "MONTH"], p.quota.period), false)
    ])
    error_message = "A usage plan quota period must be DAY, WEEK or MONTH."
  }

  validation {
    condition = alltrue([
      for _, p in var.usage_plans : p.quota == null || try(p.quota.limit > 0, false)
    ])
    error_message = "A usage plan quota limit must be greater than zero."
  }

  # API Gateway rejects an out-of-range offset when the plan is created, which
  # is after everything else in the apply has succeeded. The rules differ per
  # period and are easy to read past, so they are checked here instead.
  validation {
    condition = alltrue([
      for _, p in var.usage_plans :
      p.quota == null || try(p.quota.period != "DAY" || p.quota.offset == 0, false)
    ])
    error_message = "A DAY quota takes an offset of 0: there is no sub-day boundary to start the period on."
  }

  validation {
    condition = alltrue([
      for _, p in var.usage_plans :
      p.quota == null || try(p.quota.period != "WEEK" || (p.quota.offset >= 0 && p.quota.offset <= 6), false)
    ])
    error_message = "A WEEK quota takes an offset between 0 and 6, naming the day the period starts on."
  }

  validation {
    condition = alltrue([
      for _, p in var.usage_plans :
      p.quota == null || try(p.quota.period != "MONTH" || (p.quota.offset >= 0 && p.quota.offset <= 27), false)
    ])
    error_message = "A MONTH quota takes an offset between 0 and 27. The ceiling is 27 rather than 30 so that the period starts on a day every month has."
  }

  validation {
    condition = alltrue([
      for _, p in var.usage_plans : p.throttle != null || p.quota != null || length(p.method_throttles) > 0
    ])
    error_message = "A usage plan that sets neither a throttle, a quota nor a method throttle limits nothing. It can still be attached to keys, and it will meter every one of them against no limit at all."
  }

  validation {
    condition = alltrue(flatten([
      for _, p in var.usage_plans : [
        for _, t in p.method_throttles : t.rate_limit > 0 && t.burst_limit > 0
      ]
    ]))
    error_message = "Each usage plan method throttle rate_limit and burst_limit must be greater than zero."
  }
}

# ---------------------------------------------------------------------------
# Logging and protection
# ---------------------------------------------------------------------------

variable "access_log_retention_days" {
  description = "Retention for the stage access log group."
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

variable "access_log_kms_key_arn" {
  description = "Customer-managed key for the access log group. Its policy must already admit the CloudWatch Logs service principal in this region, or creating the group fails."
  type        = string
  default     = null

  validation {
    condition     = var.access_log_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.access_log_kms_key_arn))
    error_message = "access_log_kms_key_arn must be a KMS key ARN (an alias ARN is not accepted by the log group)."
  }
}

variable "metrics_enabled" {
  description = "Publish per-method CloudWatch metrics for the stage. Without these the only request counts available are the API-wide ones, which cannot say which method is being throttled."
  type        = bool
  default     = true
}

variable "xray_tracing_enabled" {
  description = "Sample requests into X-Ray from the stage."
  type        = bool
  default     = false
}

variable "web_acl_arn" {
  description = <<-EOT
    Regional web ACL to associate with the stage. Null leaves the stage
    unprotected.

    The ARN is checked rather than taken on trust, because the one mistake that
    matters here cannot be seen in the console afterwards: a CloudFront-scoped
    ACL and a regional one look alike, only the regional one can be attached to
    a stage, and it has to live in the API's own region. A WAFv2 ARN states
    both, so both are read out of it at plan time.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.web_acl_arn == null || can(regex("^arn:aws[a-z-]*:wafv2:[a-z0-9-]+:[0-9]{12}:(regional|global)/webacl/", var.web_acl_arn))
    error_message = "web_acl_arn must be a WAFv2 web ACL ARN."
  }

  validation {
    condition     = var.web_acl_arn == null || can(regex("^arn:aws[a-z-]*:wafv2:[a-z0-9-]+:[0-9]{12}:regional/webacl/", var.web_acl_arn))
    error_message = "web_acl_arn must be a REGIONAL web ACL. A global (CloudFront) ACL cannot be associated with an API Gateway stage, including the stage of an edge-optimized API, because the distribution in front of that API belongs to API Gateway rather than to this account."
  }
}

variable "tags" {
  description = "Tags applied to resources this module creates."
  type        = map(string)
  default     = {}
}
