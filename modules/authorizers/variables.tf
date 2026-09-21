variable "api_id" {
  description = "HTTP API these authorizers belong to. An authorizer is owned by one API and cannot be shared with another."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{6,20}$", var.api_id))
    error_message = "api_id must be an API Gateway API identifier."
  }
}

variable "api_execution_arn" {
  description = <<-EOT
    Execute-api ARN of the API, used as the stem of the invoke grant given to
    API Gateway for a Lambda authorizer.

    Taken as an input rather than rebuilt from region and account, so the grant
    and the API can never be derived from different values.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:execute-api:[a-z0-9-]+:[0-9]{12}:[a-z0-9]{6,20}$", var.api_execution_arn))
    error_message = "api_execution_arn must be the API's execute-api ARN, ending in the API id and carrying no stage, method or path."
  }
}

variable "name_prefix" {
  description = <<-EOT
    Stem of every name derived here. Kept short because the tightest limit
    downstream is the IAM role name for the bundled function, which is capped at
    64 characters and also has to carry the authorizer key and a suffix.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,26}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-28 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

# ---------------------------------------------------------------------------
# JWT authorizers
# ---------------------------------------------------------------------------

variable "jwt_authorizers" {
  description = <<-EOT
    Authorizers that verify a JWT inside API Gateway, keyed by a short stable
    name that routes refer to.

    Name either an issuer or a Cognito user pool, not both. A pool id carries
    its own region, so the issuer URL is derived from the pool rather than
    assembled from a second input that can disagree with it.

    Read the scope note in the module README before putting
    authorization_scopes on a route: API Gateway grants a scoped route to a
    token holding ANY one of the listed scopes, not all of them.
  EOT
  type = map(object({
    audience             = list(string)
    issuer               = optional(string)
    cognito_user_pool_id = optional(string)
    identity_source      = optional(string, "$request.header.Authorization")
  }))
  default = {}

  validation {
    condition     = alltrue([for k, _ in var.jwt_authorizers : can(regex("^[a-z][a-z0-9-]{0,39}$", k))])
    error_message = "Each jwt_authorizers key must be 1-40 characters, lower-case alphanumeric and hyphens, starting with a letter."
  }

  validation {
    condition = alltrue([
      for _, v in var.jwt_authorizers :
      (v.issuer == null) != (v.cognito_user_pool_id == null)
    ])
    error_message = "Each JWT authorizer must name exactly one of issuer or cognito_user_pool_id."
  }

  validation {
    condition = alltrue([
      for _, v in var.jwt_authorizers :
      v.issuer == null ? true : can(regex("^https://[^[:space:]]+$", v.issuer))
    ])
    error_message = "issuer must be an https URL. API Gateway fetches the signing keys over TLS and will not accept a plain-http issuer."
  }

  validation {
    condition = alltrue([
      for _, v in var.jwt_authorizers :
      v.issuer == null ? true : !strcontains(v.issuer, "/.well-known/")
    ])
    error_message = "issuer must be the issuer identifier, not its discovery or JWKS URL. API Gateway appends the discovery path itself, so a URL that already carries it resolves to nothing and every request is refused with no indication that the issuer is at fault."
  }

  validation {
    condition = alltrue([
      for _, v in var.jwt_authorizers :
      v.cognito_user_pool_id == null ? true : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]_[A-Za-z0-9]+$", v.cognito_user_pool_id))
    ])
    error_message = "cognito_user_pool_id must be a user pool id of the form <region>_<suffix>, for example us-east-1_ab12CD34e."
  }

  validation {
    condition     = alltrue([for _, v in var.jwt_authorizers : length(v.audience) > 0])
    error_message = "Each JWT authorizer must name at least one audience. An authorizer with no audience is accepted by the provider and refused by API Gateway, and an audience is the only thing that ties a token to this API rather than to anything else the issuer signs for."
  }

  validation {
    condition = alltrue([
      for _, v in var.jwt_authorizers :
      alltrue([for a in v.audience : length(trimspace(a)) > 0])
    ])
    error_message = "audience entries must not be blank."
  }

  validation {
    condition = alltrue([
      for _, v in var.jwt_authorizers :
      can(regex("^\\$request\\.header\\.[A-Za-z0-9-]+$", v.identity_source))
    ])
    error_message = "A JWT authorizer reads its token from one request header, so identity_source must be of the form $request.header.<name>."
  }
}

# ---------------------------------------------------------------------------
# Lambda authorizers
# ---------------------------------------------------------------------------

variable "lambda_authorizers" {
  description = <<-EOT
    Authorizers that call a function to decide a request, keyed by a short
    stable name that routes refer to.

    Each entry either names an existing function_arn or declares
    scope_enforcement, in which case this module deploys its own authorizer
    function. Naming both is refused: the decision belongs to one of them.

    result_ttl_in_seconds is always sent, never left to the provider. Left
    unset, the provider supplies 300 on its own, and which configurations it
    does that for changed inside the version range this repository pins.
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

  validation {
    condition     = alltrue([for k, _ in var.lambda_authorizers : can(regex("^[a-z][a-z0-9-]{0,23}$", k))])
    error_message = "Each lambda_authorizers key must be 1-24 characters, lower-case alphanumeric and hyphens, starting with a letter. The cap comes from the IAM role name derived for a bundled function, which is capped at 64 characters and also carries name_prefix and a suffix."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      (v.function_arn == null) != (v.scope_enforcement == null)
    ])
    error_message = "Each Lambda authorizer must either name an existing function_arn or declare scope_enforcement, and not both."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      v.function_arn == null ? true : can(regex("^arn:aws[a-z-]*:lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]+(:[A-Za-z0-9_$-]+)?$", v.function_arn))
    ])
    error_message = "function_arn must be a Lambda function ARN, optionally qualified with a version or alias."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      contains(["1.0", "2.0"], v.payload_format_version)
    ])
    error_message = "payload_format_version must be \"1.0\" or \"2.0\". The provider leaves it unset when it is not given, and API Gateway requires it for every Lambda authorizer on an HTTP API."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      v.payload_format_version == "2.0" if v.enable_simple_responses
    ])
    error_message = "enable_simple_responses requires payload_format_version \"2.0\". A 1.0 authorizer answers with an IAM policy and has no simple form."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      v.result_ttl_in_seconds >= 0 && v.result_ttl_in_seconds <= 3600
    ])
    error_message = "result_ttl_in_seconds must be between 0 and 3600. Zero turns caching off, which is what makes a token's own expiry the thing that ends access."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      length(v.identity_sources) > 0 if v.result_ttl_in_seconds > 0
    ])
    error_message = "A cached authorizer must declare at least one identity source, because the identity sources ARE the cache key. With none, there is nothing to key a cached decision on."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      alltrue([
        for s in v.identity_sources :
        can(regex("^\\$(request\\.(header|querystring)\\.[A-Za-z0-9-]+|context\\.[A-Za-z][A-Za-z0-9.]*|stageVariables\\.[A-Za-z0-9_]+)$", s))
      ])
    ])
    error_message = "Each identity source must be $request.header.<name>, $request.querystring.<name>, $context.<name> or $stageVariables.<name>."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      length(distinct(v.identity_sources)) == length(v.identity_sources)
    ])
    error_message = "identity_sources must not repeat an entry."
  }

  # The one that is easy to get wrong and impossible to see afterwards. A
  # cached decision is keyed on the identity sources alone, so an authorizer
  # that decides per route while caching on the token only will answer a second
  # route from the first route's cached decision. It passes every test that
  # exercises one route.
  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      contains(v.identity_sources, "$context.routeKey")
      if v.result_ttl_in_seconds > 0 && v.scope_enforcement != null && length(v.scope_enforcement.required_scopes) > 0
    ])
    error_message = "An authorizer that requires different scopes on different routes and caches its results must include \"$context.routeKey\" in identity_sources. Without it the cache key is the token alone, so a decision made for one route is replayed for every other route that token reaches, and the scopes on those routes stop being consulted."
  }

  # The bundled function answers in the simple form only. The policy form
  # carries a resource, and a cached policy is replayed for routes it was never
  # produced for, so the resource has to be widened to stay correct -- at which
  # point it is naming everything anyway. The simple form has no resource to
  # widen. A function supplied through function_arn may answer either way.
  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      v.payload_format_version == "2.0" && v.enable_simple_responses if v.scope_enforcement != null
    ])
    error_message = "A scope_enforcement authorizer must use payload_format_version \"2.0\" with enable_simple_responses. The bundled function answers in the simple form, and an authorizer told to expect an IAM policy will read that answer as a malformed response and fail the request."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      can(regex("^https://[^[:space:]]+$", v.scope_enforcement.issuer)) if v.scope_enforcement != null
    ])
    error_message = "scope_enforcement.issuer must be an https URL."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      !strcontains(v.scope_enforcement.issuer, "/.well-known/") if v.scope_enforcement != null
    ])
    error_message = "scope_enforcement.issuer must be the issuer identifier, not its discovery or JWKS URL; the function appends the discovery path itself."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      length(v.scope_enforcement.audience) > 0 if v.scope_enforcement != null
    ])
    error_message = "scope_enforcement.audience must name at least one audience, or any token the issuer signs for anything is accepted here."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      contains(["deny", "allow"], v.scope_enforcement.unlisted_route_action) if v.scope_enforcement != null
    ])
    error_message = "scope_enforcement.unlisted_route_action must be \"deny\" or \"allow\"."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      alltrue([
        for rk, scopes in v.scope_enforcement.required_scopes :
        rk == "$default" || can(regex("^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|ANY) /[A-Za-z0-9._~/{}+-]*$", rk))
      ]) if v.scope_enforcement != null
    ])
    error_message = "Each required_scopes key must be a route key: the literal $default, or a method and an absolute path separated by one space. It is matched against $context.routeKey, which is exactly that string."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      alltrue([
        for _, scopes in v.scope_enforcement.required_scopes :
        length(scopes) > 0 && alltrue([for s in scopes : length(trimspace(s)) > 0])
      ]) if v.scope_enforcement != null
    ])
    error_message = "A required_scopes entry must list at least one scope, and no scope may be blank. To require nothing of a route, leave it out and let unlisted_route_action decide it."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      v.scope_enforcement.jwks_cache_seconds >= 60 && v.scope_enforcement.jwks_cache_seconds <= 86400 if v.scope_enforcement != null
    ])
    error_message = "scope_enforcement.jwks_cache_seconds must be between 60 and 86400. Below a minute the function fetches keys almost every invocation; above a day a rotated-out signing key is still trusted long after the issuer stopped using it."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      v.scope_enforcement.clock_skew_seconds >= 0 && v.scope_enforcement.clock_skew_seconds <= 300 if v.scope_enforcement != null
    ])
    error_message = "scope_enforcement.clock_skew_seconds must be between 0 and 300. Skew is tolerance for clocks that disagree, not a way to extend a token's life."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      v.scope_enforcement.memory_size >= 128 && v.scope_enforcement.memory_size <= 10240 if v.scope_enforcement != null
    ])
    error_message = "scope_enforcement.memory_size must be between 128 and 10240 MB."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      v.scope_enforcement.timeout_seconds >= 1 && v.scope_enforcement.timeout_seconds <= 29 if v.scope_enforcement != null
    ])
    error_message = "scope_enforcement.timeout_seconds must be between 1 and 29. An authorizer runs inside the request, so its timeout is spent before the integration is even reached."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      contains(
        [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
        v.scope_enforcement.log_retention_days
      ) if v.scope_enforcement != null
    ])
    error_message = "scope_enforcement.log_retention_days must be one of the retention periods CloudWatch Logs accepts."
  }

  validation {
    condition = alltrue([
      for _, v in var.lambda_authorizers :
      v.scope_enforcement.log_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", v.scope_enforcement.log_kms_key_arn))
      if v.scope_enforcement != null
    ])
    error_message = "scope_enforcement.log_kms_key_arn must be a KMS key ARN (an alias ARN is not accepted by the log group)."
  }
}

variable "manage_lambda_permissions" {
  description = <<-EOT
    Grant API Gateway permission to invoke the functions behind Lambda
    authorizers.

    Turning this off leaves every route those authorizers decide answering with
    an internal server error until the grants are made elsewhere, which is the
    same answer a working authorizer gives when it denies badly; the authorizers
    affected are reported in authorizer_invocations_not_granted.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags for resources this module creates."
  type        = map(string)
  default     = {}
}
