variable "domain_name" {
  description = "Fully qualified domain name clients call."
  type        = string

  validation {
    condition     = can(regex("^(\\*\\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a lower-case fully qualified domain name, optionally a wildcard such as *.example.com."
  }

  validation {
    condition     = length(var.domain_name) <= 253
    error_message = "domain_name must be at most 253 characters."
  }
}

variable "api_kind" {
  description = <<-EOT
    Which kind of API this domain fronts: REST or HTTP.

    The two are different resources with different constraints rather than a
    preference. An HTTP API domain is regional and TLS 1.2 by construction --
    the provider accepts no other values. A REST API domain accepts EDGE as well
    as REGIONAL, and leaves the security policy for the service to choose unless
    it is told, which is why this module always states it.

    A domain fronts one kind. Base path mappings and API mappings are separate
    resources belonging to separate services, so a domain cannot be half of each
    without two things believing they own it.
  EOT
  type        = string

  validation {
    condition     = contains(["REST", "HTTP"], var.api_kind)
    error_message = "api_kind must be REST or HTTP."
  }
}

variable "certificate_arn" {
  description = "ACM certificate for the domain, issued in this region. A certificate for an edge-optimized domain lives in us-east-1 and is not usable here."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/", var.certificate_arn))
    error_message = "certificate_arn must be an ACM certificate ARN."
  }
}

variable "certificate_is_imported_or_private_ca" {
  description = <<-EOT
    Whether the certificate above was imported into ACM or issued by a private
    CA, rather than issued publicly by ACM.

    It changes what mutual TLS requires. A publicly issued ACM certificate is
    proof enough that the domain is yours; an imported or private-CA one is not,
    so API Gateway asks for a separate ACM-issued ownership verification
    certificate as well. Nothing in the ARN says which kind it is, which is why
    this is asked rather than derived.
  EOT
  type        = bool
  default     = false
}

variable "ownership_verification_certificate_arn" {
  description = <<-EOT
    ACM certificate proving the domain is yours. Required with mutual TLS when
    the domain certificate is imported or from a private CA.

    It takes no part in the handshake, and it has to stay valid for as long as
    the domain exists: if it expires and renewal fails, EVERY update to the
    domain name is locked until it is replaced -- including the truststore
    update that is the reason to be changing the domain in the first place.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.ownership_verification_certificate_arn == null || can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/", var.ownership_verification_certificate_arn))
    error_message = "ownership_verification_certificate_arn must be an ACM certificate ARN."
  }
}

variable "rest_endpoint_type" {
  description = "Endpoint type for a REST domain. Ignored for an HTTP API domain, which is regional and nothing else."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "EDGE"], var.rest_endpoint_type)
    error_message = "rest_endpoint_type must be REGIONAL or EDGE."
  }
}

variable "security_policy" {
  description = <<-EOT
    Minimum TLS version the domain negotiates.

    Always stated, never left unset. On a REST domain this field is filled in by
    the service when the configuration is silent, so an unstated policy is
    whatever AWS chose on the day -- invisible in the plan and invisible in the
    diff. Mutual TLS requires TLS 1.2 in any case.
  EOT
  type        = string
  default     = "TLS_1_2"

  validation {
    condition     = contains(["TLS_1_0", "TLS_1_2"], var.security_policy)
    error_message = "security_policy must be TLS_1_0 or TLS_1_2."
  }
}

variable "mutual_tls" {
  description = <<-EOT
    Client certificate requirement for this domain. Null leaves it off.

    truststore_bucket and truststore_key locate the PEM bundle of certificate
    authorities whose clients are trusted. It must be the complete chain from
    issuing CA to root, because API Gateway accepts a client certificate issued
    by any CA in the chain and rejects one whose chain it cannot complete.

    truststore_version is REQUIRED, and that is this module's decision rather
    than the service's. The provider sends the version only when the
    configuration's value CHANGES, so replacing the object in S3 and leaving
    this alone updates nothing: the domain keeps validating against the version
    it was last given, `terraform apply` reports no changes, and the bucket
    shows the new bundle. A removed or expired CA stays trusted. Requiring the
    version makes a rotation a change Terraform can see.

    Rotation is also the only time anything is checked: API Gateway reports
    warnings about invalid certificates when the domain is updated, and never
    notifies when a certificate already in the truststore expires.
  EOT
  type = object({
    truststore_bucket  = string
    truststore_key     = string
    truststore_version = string
  })
  default = null

  validation {
    condition = var.mutual_tls == null || can(regex(
      "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.mutual_tls.truststore_bucket
    ))
    error_message = "mutual_tls.truststore_bucket must be a valid lower-case S3 bucket name of 3-63 characters."
  }

  validation {
    condition     = var.mutual_tls == null ? true : (length(var.mutual_tls.truststore_key) > 0 && !startswith(var.mutual_tls.truststore_key, "/"))
    error_message = "mutual_tls.truststore_key must be a non-empty S3 key without a leading slash. The truststore URI is built as s3://bucket/key and a leading slash produces a key with an empty first segment."
  }

  validation {
    condition     = var.mutual_tls == null ? true : endswith(var.mutual_tls.truststore_key, ".pem")
    error_message = "mutual_tls.truststore_key must name a .pem file. A truststore is a PEM bundle; API Gateway reports a warning for a file it cannot parse, and a warning at this point is not fatal."
  }

  validation {
    condition     = var.mutual_tls == null ? true : length(trimspace(var.mutual_tls.truststore_version)) > 0
    error_message = "mutual_tls.truststore_version is required. Without it, replacing the bundle in S3 changes nothing about the domain: the version is sent only when this value changes, so the old truststore stays in force and the apply reports no changes."
  }
}

variable "create_truststore_bucket" {
  description = <<-EOT
    Whether this module creates the bucket holding the truststore.

    The bucket it creates has versioning ON and not optional, because an object
    version is what a truststore rotation is: without versioning there is no
    version to name, and the only way to point the domain at a new bundle is to
    move it to a different key.
  EOT
  type        = bool
  default     = false
}

variable "truststore_bucket_kms_key_arn" {
  description = "Key encrypting a bucket this module creates. Null uses S3-managed encryption. A truststore is a list of public certificate authorities rather than a secret, so the choice is about the account's own baseline."
  type        = string
  default     = null

  validation {
    condition     = var.truststore_bucket_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.truststore_bucket_kms_key_arn))
    error_message = "truststore_bucket_kms_key_arn must be a KMS key ARN."
  }
}

variable "api_mappings" {
  description = <<-EOT
    APIs served under this domain, keyed by a name of the caller's choosing.

    base_path is the segment after the host. Exactly one mapping may leave it
    empty, which serves that API at the root of the domain; two that do collide
    and the second is refused after the first exists.
  EOT
  type = map(object({
    api_id     = string
    stage_name = string
    base_path  = optional(string, "")
  }))
  default = {}

  validation {
    condition     = alltrue([for k, _ in var.api_mappings : can(regex("^[a-z][a-z0-9-]{1,63}$", k))])
    error_message = "Each api_mappings key must be lower-case alphanumeric with hyphens, start with a letter, and be 2-64 characters."
  }

  validation {
    condition     = alltrue([for _, v in var.api_mappings : length(trimspace(v.api_id)) > 0 && length(trimspace(v.stage_name)) > 0])
    error_message = "Each api_mappings entry needs an api_id and a stage_name. A mapping without a stage has nothing to route to."
  }

  validation {
    condition = alltrue([
      for _, v in var.api_mappings :
      v.base_path == "" || can(regex("^[a-zA-Z0-9._~-]+$", v.base_path))
    ])
    error_message = "Each api_mappings base_path must be empty or a single path segment of unreserved URL characters. A base path is one segment: a slash inside it is refused."
  }

  validation {
    condition     = length(distinct([for _, v in var.api_mappings : v.base_path])) == length(var.api_mappings)
    error_message = "Two api_mappings share a base_path. A domain routes one base path to one API and stage, so the second mapping is refused once the first exists -- leaving the domain half configured."
  }
}

variable "hosted_zone_id" {
  description = <<-EOT
    Route 53 zone the alias record is created in. Null creates no record.

    Without a record the domain is configured, reports available, and resolves
    nowhere: every call fails in DNS, which looks nothing like an API Gateway
    problem and is the most common reason a new custom domain appears not to
    work.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.hosted_zone_id == null || can(regex("^Z[A-Z0-9]{1,31}$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a Route 53 hosted zone id."
  }
}

variable "create_ipv6_record" {
  description = "Whether an AAAA alias is created alongside the A record. A client on an IPv6-only network cannot reach an A-only name."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
