variable "name" {
  description = "Name of the REST API. Also the title the rendered document carries, so the two cannot disagree."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,54}$", var.name))
    error_message = "name must be lower-case alphanumeric with hyphens, start with a letter, and be 3-55 characters. The stage's derived log group path is built from it."
  }
}

variable "description" {
  description = "Description of the API."
  type        = string
  default     = "REST API deployed from an OpenAPI document"
}

variable "openapi_body" {
  description = <<-EOT
    The rendered OpenAPI document, as a string. Render it with templatefile() in
    the caller so an unsupplied placeholder fails there, with the name of the
    placeholder, rather than reaching AWS as a literal.
  EOT
  type        = string

  validation {
    condition     = length(trimspace(var.openapi_body)) > 0
    error_message = "openapi_body is empty. An API Gateway import of an empty document is refused by the service, but the API is created first, so the apply fails with an API already in the account."
  }

  validation {
    condition     = can(yamldecode(var.openapi_body))
    error_message = "openapi_body does not parse as YAML or JSON. JSON is valid YAML, so this rejects both forms. A document that does not parse is refused by the import."
  }
}

variable "endpoint_type" {
  description = <<-EOT
    Endpoint type for the API.

    REGIONAL is the default and is a prerequisite for the custom domain that
    carries mutual TLS: an edge-optimized API cannot be reached through a
    regional domain name, and mutual TLS exists only on a regional one.
  EOT
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "EDGE", "PRIVATE"], var.endpoint_type)
    error_message = "endpoint_type must be REGIONAL, EDGE or PRIVATE."
  }
}

variable "stage_name" {
  description = "Stage the deployment is served at."
  type        = string
  default     = "v1"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,128}$", var.stage_name))
    error_message = "stage_name must be alphanumeric with underscores or hyphens, 1-128 characters."
  }
}

variable "put_rest_api_mode" {
  description = <<-EOT
    How the import treats what is already in the API.

    overwrite -- the default here and in the provider -- makes the document
    authoritative: an operation removed from it is removed from the API. That is
    the whole point of importing, and it is also why the document has to carry
    every literal property of the API that matters, because overwrite mode
    deletes the ones it does not mention.

    merge leaves anything the document does not mention in place. That keeps the
    literal properties safe and costs the property worth having: a route deleted
    from the document keeps serving, and nothing reports it. The module says
    which mode is in effect rather than leaving it to be inferred.
  EOT
  type        = string
  default     = "overwrite"

  validation {
    condition     = contains(["overwrite", "merge"], var.put_rest_api_mode)
    error_message = "put_rest_api_mode must be overwrite or merge."
  }
}

variable "fail_on_warnings" {
  description = <<-EOT
    Whether the import fails when API Gateway reports a warning.

    This defaults to true here and to FALSE in the service. Left at the service
    default, a document with an unrecognised extension key, an unresolvable
    $ref or an integration it cannot make sense of is imported anyway, minus the
    parts it could not understand: the apply succeeds, the API exists, and the
    operation is simply not there. Nothing in the plan or the state says so.
  EOT
  type        = bool
  default     = true
}

variable "disable_default_endpoint" {
  description = <<-EOT
    Whether the generated execute-api endpoint stops answering.

    It answers by default, and it does not require a client certificate. An API
    reached only through a custom domain with mutual TLS therefore has a second
    way in that asks for nothing, and every check of the domain passes while it
    is open.
  EOT
  type        = bool
  default     = false
}

variable "binary_media_types" {
  description = "Media types treated as binary. Empty means every response is handled as text, which corrupts an image or a PDF rather than failing."
  type        = list(string)
  default     = []
}

variable "minimum_compression_size" {
  description = "Smallest response, in bytes, that API Gateway compresses. Null leaves compression off."
  type        = number
  default     = null

  validation {
    condition     = var.minimum_compression_size == null || (var.minimum_compression_size >= 0 && var.minimum_compression_size <= 10485760)
    error_message = "minimum_compression_size must be between 0 and 10485760 bytes."
  }
}

variable "lambda_integrations" {
  description = <<-EOT
    Invocation grants for the functions the document integrates with, keyed by a
    name of the caller's choosing.

    Importing a document does not create these. The console adds the grant when
    an integration is created through it; an import does not, so a document that
    is correct in every other respect answers 500 on the first call. The failure
    reads as a broken function rather than a missing permission, because an HTTP
    API and a REST API both answer a missing grant the same way they answer a
    handler that threw.

    http_method and path narrow the grant. Left at their defaults the grant
    covers every method and path on the stage, which is correct for a proxy
    integration serving the whole API and wider than necessary for one function
    behind one route.
  EOT
  type = map(object({
    function_name = string
    http_method   = optional(string, "*")
    path          = optional(string, "/*")
  }))
  default = {}

  validation {
    condition     = alltrue([for k, _ in var.lambda_integrations : can(regex("^[a-z][a-z0-9-]{1,63}$", k))])
    error_message = "Each lambda_integrations key must be lower-case alphanumeric with hyphens, start with a letter, and be 2-64 characters."
  }

  validation {
    condition     = alltrue([for _, v in var.lambda_integrations : length(trimspace(v.function_name)) > 0])
    error_message = "Each lambda_integrations entry needs a function_name. A function ARN is accepted here too, since the permission resource takes either."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_integrations :
      contains(["*", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "ANY"], v.http_method)
    ])
    error_message = "Each lambda_integrations http_method must be * or a single HTTP method. A grant naming a method the document does not serve matches nothing."
  }

  validation {
    condition     = alltrue([for _, v in var.lambda_integrations : startswith(v.path, "/")])
    error_message = "Each lambda_integrations path must start with a slash. The source ARN is built from it and a path without one produces a grant that can never match."
  }
}

variable "stage_throttle" {
  description = <<-EOT
    Stage-wide rate and burst ceiling.

    This is the only aggregate limit the API has. Null leaves the account limit
    as the only ceiling, which is shared with every other API in the account and
    region -- so one API's traffic is the reason another one is throttled.
  EOT
  type = object({
    rate_limit  = number
    burst_limit = number
  })
  default = null

  validation {
    condition     = var.stage_throttle == null || (var.stage_throttle.rate_limit > 0 && var.stage_throttle.burst_limit > 0)
    error_message = "stage_throttle rate_limit and burst_limit must both be above zero. Zero is a limit of zero requests, not an absent limit -- the module writes -1 for that."
  }
}

variable "metrics_enabled" {
  description = "Whether CloudWatch metrics are collected per method."
  type        = bool
  default     = true
}

variable "xray_tracing_enabled" {
  description = "Whether X-Ray traces the stage."
  type        = bool
  default     = true
}

variable "access_log_retention_days" {
  description = "Retention for the access log group."
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
  description = "Key encrypting the access log group. The key's policy has to admit CloudWatch Logs for this group before the group is created."
  type        = string
  default     = null

  validation {
    condition     = var.access_log_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.access_log_kms_key_arn))
    error_message = "access_log_kms_key_arn must be a KMS key ARN. An alias ARN is accepted by some resources and refused by this one."
  }
}

variable "log_client_certificate_fields" {
  description = <<-EOT
    Whether the access log records which client certificate was presented.

    Worth having wherever mutual TLS is in use: the subject and issuer are the
    only record of which certificate a request arrived with, and API Gateway
    checks neither revocation nor expiry of a certificate already in the
    truststore. Worth thinking about first: the subject distinguished name
    identifies the caller, and the log group holds it for as long as its
    retention allows.

    The certificate itself is never logged. The PEM is available as a context
    variable and putting it in an access log writes a client's whole certificate
    into CloudWatch on every request.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
