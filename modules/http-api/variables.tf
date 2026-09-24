variable "name" {
  description = <<-EOT
    Name of the API and the stem of every name derived from it. Kept short
    because the tightest downstream limit is the Lambda permission statement id,
    which is capped at 100 characters and also has to carry a route key.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,26}[a-z0-9]$", var.name))
    error_message = "name must be 3-28 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "description" {
  description = "Description recorded on the API."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Integrations
# ---------------------------------------------------------------------------

variable "integrations" {
  description = <<-EOT
    Backends this API can reach, keyed by a short stable name that routes refer
    to. Declaring an integration does not expose it; a route is what makes it
    reachable.
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

  validation {
    condition     = alltrue([for k, _ in var.integrations : can(regex("^[a-z][a-z0-9-]{0,39}$", k))])
    error_message = "Each integration key must be 1-40 characters, lower-case alphanumeric and hyphens, starting with a letter."
  }

  validation {
    condition     = alltrue([for _, v in var.integrations : contains(["AWS_PROXY", "HTTP_PROXY"], v.type)])
    error_message = "integration type must be AWS_PROXY (a Lambda function) or HTTP_PROXY (an HTTP endpoint or a load balancer listener)."
  }

  validation {
    condition = alltrue([
      for _, v in var.integrations :
      can(regex("^arn:aws[a-z-]*:lambda:[a-z0-9-]+:[0-9]{12}:function:", v.uri)) if v.type == "AWS_PROXY"
    ])
    error_message = "An AWS_PROXY integration uri must be a Lambda function ARN."
  }

  validation {
    condition = alltrue([
      for _, v in var.integrations :
      can(regex("^https://", v.uri)) || can(regex("^arn:aws[a-z-]*:(elasticloadbalancing|servicediscovery):", v.uri)) if v.type == "HTTP_PROXY"
    ])
    error_message = "An HTTP_PROXY integration uri must be an https:// URL, a load balancer listener ARN, or a Cloud Map service ARN."
  }

  validation {
    condition = alltrue([
      for _, v in var.integrations :
      v.integration_method != null if v.type == "HTTP_PROXY"
    ])
    error_message = "An HTTP_PROXY integration must declare integration_method; there is no method to infer from the route, because one route can forward to a different verb."
  }

  validation {
    condition = alltrue([
      for _, v in var.integrations :
      v.integration_method == null if v.type == "AWS_PROXY"
    ])
    error_message = "integration_method does not apply to an AWS_PROXY integration: a Lambda proxy integration is always invoked with POST."
  }

  validation {
    condition = alltrue([
      for _, v in var.integrations :
      v.integration_method == null ? true : contains(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "ANY"], v.integration_method)
    ])
    error_message = "integration_method must be one of GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS, ANY."
  }

  validation {
    condition     = alltrue([for _, v in var.integrations : contains(["1.0", "2.0"], v.payload_format_version)])
    error_message = "payload_format_version must be \"1.0\" or \"2.0\"."
  }

  validation {
    condition = alltrue([
      for _, v in var.integrations :
      v.timeout_milliseconds >= 50 && v.timeout_milliseconds <= 30000
    ])
    error_message = "timeout_milliseconds must be between 50 and 30000: 30 seconds is the ceiling an HTTP API integration can be given, and a backend allowed longer than that returns 504 to the client while its own work continues."
  }

  validation {
    condition     = alltrue([for _, v in var.integrations : contains(["INTERNET", "VPC_LINK"], v.connection_type)])
    error_message = "connection_type must be INTERNET or VPC_LINK."
  }

  validation {
    condition = alltrue([
      for _, v in var.integrations :
      v.vpc_link_id != null if v.connection_type == "VPC_LINK"
    ])
    error_message = "A VPC_LINK integration must name vpc_link_id. This module does not create VPC links; a link is shared network plumbing that outlives any one API."
  }

  validation {
    condition = alltrue([
      for _, v in var.integrations :
      v.vpc_link_id == null if v.connection_type == "INTERNET"
    ])
    error_message = "vpc_link_id is only meaningful when connection_type is VPC_LINK."
  }

  validation {
    condition = alltrue([
      for _, v in var.integrations :
      v.type == "HTTP_PROXY" if v.connection_type == "VPC_LINK"
    ])
    error_message = "A VPC link carries an HTTP_PROXY integration. A Lambda function is reached through the Lambda service endpoint, not through a VPC link."
  }
}

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

variable "routes" {
  description = <<-EOT
    Routes exposed by the API, keyed by a short stable name. The route_key is
    the method and path pair API Gateway matches on, or the literal $default,
    which catches every request no other route matched.
  EOT
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

  validation {
    condition     = alltrue([for k, _ in var.routes : can(regex("^[a-z][a-z0-9-]{0,39}$", k))])
    error_message = "Each route key must be 1-40 characters, lower-case alphanumeric and hyphens, starting with a letter."
  }

  validation {
    condition = alltrue([
      for _, v in var.routes :
      v.route_key == "$default" || can(regex("^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|ANY) /[A-Za-z0-9._~/{}+-]*$", v.route_key))
    ])
    error_message = "route_key must be the literal $default, or a method and an absolute path separated by one space, for example \"GET /items/{id}\"."
  }

  validation {
    condition = alltrue([
      for _, v in var.routes :
      v.route_key == "$default" || !strcontains(v.route_key, "+}") || can(regex("\\{[A-Za-z0-9._-]+\\+\\}$", v.route_key))
    ])
    error_message = "A greedy path variable such as {proxy+} matches the rest of the path, so it can only be the last segment of a route_key."
  }

  validation {
    condition = alltrue([
      for _, v in var.routes :
      contains(["NONE", "JWT", "AWS_IAM", "CUSTOM"], v.authorization_type)
    ])
    error_message = "authorization_type must be NONE, JWT, AWS_IAM or CUSTOM."
  }

  validation {
    condition = alltrue([
      for _, v in var.routes :
      v.authorizer_id != null if contains(["JWT", "CUSTOM"], v.authorization_type)
    ])
    error_message = "A JWT or CUSTOM route must name the authorizer_id that decides it."
  }

  validation {
    condition = alltrue([
      for _, v in var.routes :
      v.authorizer_id == null if contains(["NONE", "AWS_IAM"], v.authorization_type)
    ])
    error_message = "authorizer_id applies only to a JWT or CUSTOM route. AWS_IAM is decided by SigV4 and an IAM policy, and NONE is decided by nothing."
  }

  validation {
    condition = alltrue([
      for _, v in var.routes :
      length(v.authorization_scopes) == 0 if v.authorization_type != "JWT"
    ])
    error_message = "authorization_scopes are read from a JWT claim, so they apply only to a JWT route. On any other route they are accepted and enforce nothing."
  }

  validation {
    condition = alltrue([
      for _, v in var.routes :
      (v.throttling_burst_limit == null ? true : v.throttling_burst_limit > 0) &&
      (v.throttling_rate_limit == null ? true : v.throttling_rate_limit > 0)
    ])
    error_message = "Per-route throttling limits must be greater than zero when set. Zero is not a way to disable a route; remove the route instead."
  }
}

# ---------------------------------------------------------------------------
# CORS
# ---------------------------------------------------------------------------

variable "cors_configuration" {
  description = <<-EOT
    Cross-origin configuration for the API. Leave null when the API is not
    called from a browser.

    Configuring this takes CORS away from the integration entirely: API Gateway
    answers preflight OPTIONS requests itself, even with no OPTIONS route, and
    it discards any CORS headers the integration returns.
  EOT
  type = object({
    allow_origins     = list(string)
    allow_methods     = optional(list(string), ["GET", "HEAD", "OPTIONS"])
    allow_headers     = optional(list(string), ["authorization", "content-type"])
    expose_headers    = optional(list(string), [])
    allow_credentials = optional(bool, false)
    max_age           = optional(number, 300)
  })
  default = null

  validation {
    condition     = var.cors_configuration == null ? true : length(var.cors_configuration.allow_origins) > 0
    error_message = "cors_configuration.allow_origins must name at least one origin. An empty list is a CORS configuration that allows nothing and still takes CORS handling away from the integration."
  }

  validation {
    condition = (
      var.cors_configuration == null ||
      !var.cors_configuration.allow_credentials ||
      !contains(var.cors_configuration.allow_origins, "*")
    )
    error_message = "allow_credentials cannot be combined with the \"*\" origin: a browser refuses any response that carries credentials alongside a wildcard Access-Control-Allow-Origin, so the pair deploys cleanly and fails only in the browser. Name the origins instead."
  }

  validation {
    condition = (
      var.cors_configuration == null ||
      alltrue([
        for m in var.cors_configuration.allow_methods :
        contains(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "*"], m)
      ])
    )
    error_message = "cors_configuration.allow_methods entries must be HTTP methods or \"*\"."
  }

  validation {
    condition = (
      var.cors_configuration == null ||
      (var.cors_configuration.max_age >= 0 && var.cors_configuration.max_age <= 86400)
    )
    error_message = "cors_configuration.max_age must be between 0 and 86400 seconds."
  }
}

# ---------------------------------------------------------------------------
# Stage and deployment
# ---------------------------------------------------------------------------

variable "stage_name" {
  description = <<-EOT
    Stage serving the API. The default $default stage is served at the root of
    the API endpoint; any other name is served underneath /<stage_name>, so
    renaming a stage changes the base path of every client.
  EOT
  type        = string
  default     = "$default"

  validation {
    condition     = var.stage_name == "$default" || can(regex("^[A-Za-z0-9_-]{1,128}$", var.stage_name))
    error_message = "stage_name must be the literal $default or 1-128 characters of letters, digits, underscores and hyphens."
  }
}

variable "stage_auto_deploy" {
  description = <<-EOT
    Redeploy the stage whenever the API changes. Leaving this off means route
    and integration changes are applied to the API and never served, which is
    why turning it off requires a deployment identifier to be supplied.
  EOT
  type        = bool
  default     = true
}

variable "stage_deployment_id" {
  description = "Deployment served by the stage when stage_auto_deploy is false. This module does not create deployments; gating a release is a pipeline concern."
  type        = string
  default     = null
}

variable "default_throttling_burst_limit" {
  description = "Stage-wide burst ceiling, applied to any route that does not set its own."
  type        = number
  default     = 500

  validation {
    condition     = var.default_throttling_burst_limit > 0
    error_message = "default_throttling_burst_limit must be greater than zero."
  }
}

variable "default_throttling_rate_limit" {
  description = "Stage-wide steady-state ceiling in requests per second, applied to any route that does not set its own. A value above the account's own regional quota is accepted and the account quota is what applies."
  type        = number
  default     = 1000

  validation {
    condition     = var.default_throttling_rate_limit > 0
    error_message = "default_throttling_rate_limit must be greater than zero."
  }
}

variable "detailed_metrics_enabled" {
  description = "Publish per-route CloudWatch metrics for the stage. Off by default because per-route metrics are billed per metric and the count grows with the route table."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Access logging
# ---------------------------------------------------------------------------

variable "access_log_group_name" {
  description = "Existing log group to receive access logs. Leave null to have this module create one."
  type        = string
  default     = null
}

variable "access_log_retention_days" {
  description = "Retention for a log group this module creates."
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
  description = "Customer-managed key encrypting a log group this module creates. The key policy must already admit logs.<region>.amazonaws.com, because CloudWatch Logs uses the key directly and the group cannot be created otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.access_log_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.access_log_kms_key_arn))
    error_message = "access_log_kms_key_arn must be a KMS key ARN (an alias ARN is not accepted by the log group)."
  }
}

variable "access_log_format" {
  description = <<-EOT
    Access log format. Leave null to use this module's format, which carries the
    fields that name a cause rather than only reporting one.

    A supplied format must contain $context.integrationErrorMessage. An HTTP API
    has no execution logging, so the access log is the only place the reason for
    a 5xx is ever written, and every format offered in the console omits that
    field.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.access_log_format == null ? true : strcontains(var.access_log_format, "$context.integrationErrorMessage")
    error_message = "A supplied access_log_format must include $context.integrationErrorMessage, or an integration failure is logged as a bare 5xx with no cause recorded anywhere."
  }

  validation {
    condition     = var.access_log_format == null ? true : length(trimspace(var.access_log_format)) > 0
    error_message = "access_log_format must not be blank."
  }
}

# ---------------------------------------------------------------------------
# Endpoint exposure and invocation grants
# ---------------------------------------------------------------------------

variable "disable_default_endpoint" {
  description = <<-EOT
    Refuse requests to the generated execute-api endpoint.

    Off by default, because with no custom domain in front of the API this is
    the only way to reach it. It should be turned on as soon as a custom domain
    exists: anything attached to the domain rather than to the stage, mutual TLS
    in particular, is bypassed entirely by a client that keeps using the
    generated endpoint.
  EOT
  type        = bool
  default     = false
}

variable "manage_lambda_permissions" {
  description = "Grant API Gateway permission to invoke the Lambda functions behind AWS_PROXY routes. Turning this off leaves every route to fail with an internal server error until the grants are made elsewhere; the routes affected are reported in lambda_permissions_not_managed."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags for resources this module creates."
  type        = map(string)
  default     = {}
}
