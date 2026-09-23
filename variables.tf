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

# ---------------------------------------------------------------------------
# REST API
# ---------------------------------------------------------------------------

variable "enable_rest_api" {
  description = <<-EOT
    Deploy the REST API alongside the HTTP API.

    Off by default, and the reason it exists at all is that three things have
    no HTTP API form: API keys, usage plans, and an AWS WAF web ACL. None is a
    setting that can be turned on later. An API that has to tell its callers
    apart, cap them, or sit behind a firewall is a REST API from the start.
  EOT
  type        = bool
  default     = false
}

variable "rest_api_name" {
  description = "Name of the REST API."
  type        = string
  default     = "platform-rest-api"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.rest_api_name))
    error_message = "rest_api_name must be 3-40 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "rest_api_description" {
  description = "Description recorded on the REST API."
  type        = string
  default     = "REST API with metered access"
}

variable "rest_api_endpoint_type" {
  description = "Where the REST API is served from. A web ACL attaches to the stage in every case, and has to be a regional one even for EDGE."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "EDGE", "PRIVATE"], var.rest_api_endpoint_type)
    error_message = "rest_api_endpoint_type must be REGIONAL, EDGE or PRIVATE."
  }
}

variable "rest_api_stage_name" {
  description = "Stage serving the REST API. It appears in the invoke URL."
  type        = string
  default     = "live"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,128}$", var.rest_api_stage_name))
    error_message = "rest_api_stage_name must be 1-128 characters of letters, digits, underscores and hyphens."
  }
}

variable "rest_api_methods" {
  description = <<-EOT
    Methods the REST API exposes. Empty by default, for the same reason the
    HTTP API's routes are: every integration names something owned outside this
    configuration. See modules/rest-api for the full contract.
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
}

variable "rest_api_stage_throttle" {
  description = "Aggregate throttle for the whole stage. Null leaves it at the account limit, which means the only limits in force are per key and therefore multiply by the number of clients."
  type = object({
    rate_limit  = number
    burst_limit = number
  })
  default = null
}

variable "rest_api_method_throttles" {
  description = "Aggregate per-method throttles for the stage, keyed by the same key used in rest_api_methods."
  type = map(object({
    rate_limit  = number
    burst_limit = number
  }))
  default = {}
}

variable "rest_api_keys" {
  description = "API keys to create. A key identifies a caller for metering; it authorizes nothing. Generated values are held in Terraform state."
  type = map(object({
    description = optional(string)
    enabled     = optional(bool, true)
  }))
  default = {}
}

variable "rest_api_usage_plans" {
  description = "Usage plans. Throttles and quotas inside a plan apply per API key and are best-effort targets rather than guaranteed ceilings."
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
}

# ---------------------------------------------------------------------------
# Web ACL
# ---------------------------------------------------------------------------

variable "enable_waf" {
  description = <<-EOT
    Create a regional web ACL and associate it with the REST API stage.

    Off by default. A web ACL is a running charge and it can only protect a
    REST API stage, so it is turned on together with one rather than alongside
    an HTTP API it cannot reach.
  EOT
  type        = bool
  default     = false
}

variable "waf_name" {
  description = "Name of the web ACL. Null derives one from name_prefix."
  type        = string
  default     = null

  validation {
    condition     = var.waf_name == null || can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.waf_name))
    error_message = "waf_name must be 3-40 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "waf_enforced_rule_groups" {
  description = "Managed rule groups permitted to block. Empty means every group is evaluated in count mode, which is what makes the first weeks of an ACL readable rather than an incident."
  type        = set(string)
  default     = []
}

variable "waf_rate_limit_per_five_minutes" {
  description = "Requests one address may make in five minutes before the rate-based rule acts. Null disables the rule. The window is five minutes, not one second."
  type        = number
  default     = null
}

variable "waf_allowed_ip_addresses" {
  description = "Addresses admitted ahead of every other rule, as IPv4 CIDRs. Anything listed here bypasses the managed rule groups as well."
  type        = list(string)
  default     = []
}

variable "waf_blocked_ip_addresses" {
  description = "Addresses refused outright, as IPv4 CIDRs."
  type        = list(string)
  default     = []
}

variable "waf_capacity_budget" {
  description = "Capacity, in WCUs, the web ACL is allowed to declare. The basic web ACL price covers 1500; above that is charged."
  type        = number
  default     = 1500
}

# ---------------------------------------------------------------------------
# OpenAPI-driven API
# ---------------------------------------------------------------------------

variable "enable_openapi_api" {
  description = <<-EOT
    Whether the OpenAPI-driven REST API is created.

    Off by default, because the document integrates with a function this
    configuration does not create: enabling it without naming one would build an
    API whose every path answers 500. The same call as enable_proxy and
    enable_rest_api elsewhere -- a capability that needs a value only the caller
    has is declared off rather than given an invented default.
  EOT
  type        = bool
  default     = false
}

variable "openapi_api_name" {
  description = "Name of the OpenAPI-driven API. Also the title rendered into the document, so the two cannot disagree."
  type        = string
  default     = "orders"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,54}$", var.openapi_api_name))
    error_message = "openapi_api_name must be lower-case alphanumeric with hyphens, start with a letter, and be 3-55 characters."
  }
}

variable "openapi_document_path" {
  description = "Path to the OpenAPI document, relative to the root module. It is rendered with templatefile, so a placeholder it does not supply fails here by name."
  type        = string
  default     = "openapi/orders-api.yaml"
}

variable "openapi_orders_function_arn" {
  description = <<-EOT
    ARN of the function serving the order paths in the document.

    Required when enable_openapi_api is set, and checked rather than defaulted:
    a placeholder ARN renders into the integration URI, imports without
    complaint, and answers 500 on every call.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.openapi_orders_function_arn == null || can(regex("^arn:aws[a-z-]*:lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9-_]+(:(\\$LATEST|[A-Za-z0-9-_]+))?$", var.openapi_orders_function_arn))
    error_message = "openapi_orders_function_arn must be a Lambda function ARN, optionally qualified with a version or alias."
  }
}

variable "openapi_stage_name" {
  description = "Stage the imported document is served at."
  type        = string
  default     = "v1"
}

variable "openapi_endpoint_type" {
  description = "Endpoint type for the OpenAPI-driven API. Regional is a prerequisite for a regional custom domain, which is the only kind that can carry mutual TLS."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "EDGE", "PRIVATE"], var.openapi_endpoint_type)
    error_message = "openapi_endpoint_type must be REGIONAL, EDGE or PRIVATE."
  }
}

variable "openapi_integration_timeout_ms" {
  description = <<-EOT
    Integration timeout rendered into the document, in milliseconds.

    Capped at 29000 because that is the REST API ceiling. A backend allowed
    longer than the gateway will wait answers the client 504 while its own work
    continues -- and is billed -- so a retry duplicates it.
  EOT
  type        = number
  default     = 29000

  validation {
    condition     = var.openapi_integration_timeout_ms >= 50 && var.openapi_integration_timeout_ms <= 29000
    error_message = "openapi_integration_timeout_ms must be between 50 and 29000. The service applies no client-side check, so a larger value is accepted and then ignored in favour of the ceiling."
  }
}

variable "openapi_put_rest_api_mode" {
  description = "overwrite makes the document authoritative; merge leaves operations deleted from it serving. See modules/openapi-api/README.md."
  type        = string
  default     = "overwrite"

  validation {
    condition     = contains(["overwrite", "merge"], var.openapi_put_rest_api_mode)
    error_message = "openapi_put_rest_api_mode must be overwrite or merge."
  }
}

variable "openapi_disable_default_endpoint" {
  description = <<-EOT
    Whether the generated execute-api endpoint for the OpenAPI-driven API stops
    answering.

    Off by default so the API is reachable before a domain exists. Required on
    once mutual TLS is in force, because that endpoint asks for no certificate
    and turning mutual TLS on does not change it.
  EOT
  type        = bool
  default     = false
}

variable "openapi_stage_throttle" {
  description = "Stage-wide rate and burst ceiling for the OpenAPI-driven API."
  type = object({
    rate_limit  = number
    burst_limit = number
  })
  default = null
}

# ---------------------------------------------------------------------------
# Custom domain and mutual TLS
# ---------------------------------------------------------------------------

variable "enable_custom_domain" {
  description = "Whether a custom domain name is created. Mutual TLS is only available on one, so it is also the switch that makes client certificates possible."
  type        = bool
  default     = false
}

variable "custom_domain_name" {
  description = "Fully qualified domain name clients call."
  type        = string
  default     = null

  validation {
    condition     = var.custom_domain_name == null || can(regex("^(\\*\\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.custom_domain_name))
    error_message = "custom_domain_name must be a lower-case fully qualified domain name."
  }
}

variable "custom_domain_api_kind" {
  description = <<-EOT
    Which kind of API the domain fronts: REST or HTTP.

    A domain fronts one. A base path mapping and an API mapping are different
    resources in different services, so a domain carrying both would have two
    things believing they own it.
  EOT
  type        = string
  default     = "REST"

  validation {
    condition     = contains(["REST", "HTTP"], var.custom_domain_api_kind)
    error_message = "custom_domain_api_kind must be REST or HTTP."
  }
}

variable "custom_domain_certificate_arn" {
  description = "ACM certificate for the domain, issued in this region."
  type        = string
  default     = null

  validation {
    condition     = var.custom_domain_certificate_arn == null || can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/", var.custom_domain_certificate_arn))
    error_message = "custom_domain_certificate_arn must be an ACM certificate ARN."
  }
}

variable "custom_domain_certificate_is_imported_or_private_ca" {
  description = "Whether that certificate was imported into ACM or issued by a private CA. Mutual TLS with either needs a separate ownership verification certificate."
  type        = bool
  default     = false
}

variable "custom_domain_ownership_verification_certificate_arn" {
  description = "ACM certificate proving domain ownership. It must stay valid for the life of the domain: if it expires, every update to the domain is locked, including a truststore rotation."
  type        = string
  default     = null
}

variable "custom_domain_endpoint_type" {
  description = "Endpoint type for a REST domain. Mutual TLS requires REGIONAL."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "EDGE"], var.custom_domain_endpoint_type)
    error_message = "custom_domain_endpoint_type must be REGIONAL or EDGE."
  }
}

variable "custom_domain_security_policy" {
  description = "Minimum TLS version the domain negotiates. Always stated, because a REST domain left silent takes whatever the service chose."
  type        = string
  default     = "TLS_1_2"

  validation {
    condition     = contains(["TLS_1_0", "TLS_1_2"], var.custom_domain_security_policy)
    error_message = "custom_domain_security_policy must be TLS_1_0 or TLS_1_2."
  }
}

variable "custom_domain_mutual_tls" {
  description = <<-EOT
    Client certificate requirement for the domain. Null leaves it off.

    truststore_version is required. The provider sends it only when this value
    changes, so replacing the bundle in S3 and leaving this alone updates
    nothing: the old truststore stays in force while the apply reports no
    changes and the bucket shows the new file.
  EOT
  type = object({
    truststore_bucket  = string
    truststore_key     = string
    truststore_version = string
  })
  default = null
}

variable "custom_domain_create_truststore_bucket" {
  description = "Whether the truststore bucket is created here, with versioning on. An object version is what a truststore rotation is, so a bucket without versioning has none to name."
  type        = bool
  default     = false
}

variable "custom_domain_openapi_base_path" {
  description = "Base path the OpenAPI-driven API is served at under the domain. Empty serves it at the root, and only one API may."
  type        = string
  default     = "orders"
}

variable "custom_domain_rest_base_path" {
  description = "Base path the metered REST API is served at under the domain."
  type        = string
  default     = "metered"
}

variable "custom_domain_http_base_path" {
  description = "Base path the HTTP API is served at under the domain. Empty serves it at the root."
  type        = string
  default     = ""
}

variable "custom_domain_hosted_zone_id" {
  description = "Route 53 zone the alias records are created in. Null creates none, and the domain then resolves nowhere."
  type        = string
  default     = null
}

variable "allow_default_endpoint_with_mutual_tls" {
  description = <<-EOT
    Permits mutual TLS alongside a generated endpoint that still answers.

    Off by default, and off is the honest setting: that endpoint requires no
    client certificate, so while it answers the certificate requirement is
    optional in practice and every check of the domain still passes. On is a
    migration window for callers who have not moved to the domain yet, and it is
    reported for as long as it lasts.
  EOT
  type        = bool
  default     = false
}
