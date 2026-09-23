output "domain_name" {
  description = "The custom domain name clients call."
  value       = var.domain_name
}

output "api_kind" {
  description = "Which kind of API this domain fronts. It fronts one: the two kinds use different mapping resources."
  value       = var.api_kind
}

output "domain_arn" {
  description = "ARN of the domain name resource."
  value       = local.is_rest ? one(aws_api_gateway_domain_name.rest[*].arn) : one(aws_apigatewayv2_domain_name.http[*].arn)
}

output "endpoint_type" {
  description = "Endpoint type in force. Always REGIONAL for an HTTP API domain, whatever was asked for, because the provider accepts nothing else."
  value       = local.effective_endpoint_type
}

output "security_policy" {
  description = "Minimum TLS version negotiated. Always stated by this module rather than left for the service to choose."
  value       = var.security_policy
}

output "alias_target" {
  description = "Target an alias record points at. Useful when the record is created outside this module."
  value       = local.alias_target_name
}

output "alias_zone_id" {
  description = "Hosted zone of the alias target, which is API Gateway's zone and not the caller's."
  value       = local.alias_zone_id
}

output "record_types_created" {
  description = "Record types created in the caller's zone. Empty when no zone was supplied."
  value       = sort([for t in local.record_types : t])
}

output "base_paths" {
  description = "Base path each mapped API is served at, by mapping name. An empty string is the root of the domain."
  value       = { for key, mapping in var.api_mappings : key => mapping.base_path }
}

output "invoke_urls" {
  description = "URL each mapped API is reachable at through this domain."
  value = {
    for key, mapping in var.api_mappings :
    key => mapping.base_path == "" ? "https://${var.domain_name}/" : "https://${var.domain_name}/${mapping.base_path}"
  }
}

output "mutual_tls_enabled" {
  description = "Whether a client certificate is required at this domain."
  value       = local.mutual_tls_enabled
}

output "truststore_uri" {
  description = "Truststore the domain validates client certificates against. Null when mutual TLS is off."
  value       = local.truststore_uri
}

output "truststore_version" {
  description = "Object version in force. This is what the domain actually validates against -- not whatever is currently newest at that key."
  value       = local.mutual_tls_enabled ? var.mutual_tls.truststore_version : null
}

output "truststore_bucket_created" {
  description = "Whether this module created the truststore bucket. A bucket it created has versioning on and not optional, because an object version is what a rotation is."
  value       = local.create_truststore_bucket
}

# ---------------------------------------------------------------------------
# What mutual TLS does not do
# ---------------------------------------------------------------------------
#
# Each of these is a property of the service rather than of this configuration,
# and each one is a thing people reasonably assume mutual TLS covers.

output "rotating_the_truststore_requires_changing_the_version" {
  description = <<-EOT
    Always true, and the reason truststore_version is a required input.

    Uploading a new bundle to the same key does not change what the domain
    validates against. The version is sent only when the configured value
    changes, so a rotation done in S3 alone leaves the old truststore in force
    while `terraform apply` reports no changes and the bucket shows the new file.
    A CA removed from the bundle stays trusted.
  EOT
  value       = true
}

output "certificate_revocation_not_checked" {
  description = <<-EOT
    Always true. API Gateway checks a client certificate's syntax, integrity,
    validity period and chain against the truststore. It does not check whether
    the certificate has been revoked, so a revoked but unexpired certificate is
    accepted. Checking revocation means a Lambda authorizer, which receives the
    certificate the client presented -- modules/authorizers/ is where one goes.
  EOT
  value       = true
}

output "truststore_certificate_expiry_not_notified" {
  description = <<-EOT
    Always true. API Gateway reports warnings about invalid certificates when a
    domain name is created or updated, and at no other time -- so a CA in the
    truststore that expires next month is reported by nothing. Rotating the
    truststore is therefore also the only occasion on which it is inspected.
  EOT
  value       = true
}

output "handshake_failures_are_not_distinguished" {
  description = <<-EOT
    Always true. A certificate that is untrusted, one that has expired, and one
    using an algorithm API Gateway does not support all fail the handshake and
    are answered with 403. The response does not say which, so the record of what
    was presented is the access log's client certificate fields -- which is why
    the API module logs the subject, issuer, serial and expiry.
  EOT
  value       = true
}

output "mutual_tls_is_not_available_for_private_apis" {
  description = "Always true. Mutual TLS requires a public regional domain; a private API is reached through a VPC endpoint and cannot have one."
  value       = true
}

output "route53_records_not_created" {
  description = "True when no hosted zone was supplied. The domain is then configured and resolves nowhere, which fails in DNS and looks nothing like an API Gateway problem."
  value       = !local.create_records
}

output "ipv6_record_not_created" {
  description = "True when only an A record exists. A client on an IPv6-only network cannot reach the name."
  value       = local.create_records && !local.create_ipv6_record
}
