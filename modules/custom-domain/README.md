# modules/custom-domain

A custom domain name for an API, and optionally the client certificate
requirement that only a custom domain can carry.

## Mutual TLS belongs to the domain, not to the API

There is no setting on an API that requires a client certificate. The
requirement lives on the domain name clients reach the API through, which is why
it is configured here and why turning it on is bound up with two conditions that
are easy to satisfy separately and to miss together.

**The domain must be regional.** An edge-optimized domain terminates TLS in a
CloudFront distribution API Gateway owns, and that cannot ask a client for a
certificate. This module refuses the combination rather than accepting it.

**The API's own generated endpoint must stop answering.** This is the one that
is invisible. Enabling mutual TLS makes a certificate mandatory *at this domain*
and changes nothing about the `execute-api` URL API Gateway generated for the
API. Anything still holding that URL keeps working, with no certificate, and
every check made against the domain passes. The API modules take
`disable_default_endpoint` for this reason, and the root configuration refuses
mutual TLS alongside an endpoint that still answers.

## The truststore version is required, and that is the point

`mutual_tls.truststore_version` is a required field. The service treats it as
optional; this module does not, because of how an update is actually sent.

The provider sends the truststore version **only when the configured value
changes**. So the obvious rotation — upload a new bundle to the same key, run
`terraform apply` — does nothing at all. The domain keeps validating against the
version it was last given. `apply` reports no changes. The bucket shows the new
file. A certificate authority removed from the bundle is still trusted, and
nothing anywhere reports the gap.

Requiring the version makes a rotation a change Terraform can see:

```bash
aws s3api put-object \
  --bucket <your-truststore-bucket> --key truststore.pem \
  --body truststore.pem --query VersionId --output text
# then set that value as mutual_tls.truststore_version and apply
```

The same call is also the only time anything in the truststore is inspected.
API Gateway reports warnings about invalid certificates when a domain name is
created or updated, and at no other time — so a CA that expires next month is
reported by nothing, and rotating is the occasion on which you find out.

## What mutual TLS does not do

Four properties of the service, each one something people reasonably assume is
covered. Every one has an output saying so, because a security control that is
believed to do more than it does is worse than a missing one.

| Not covered | Consequence | Where it is handled instead |
|---|---|---|
| Revocation | A revoked but unexpired certificate is accepted | A Lambda authorizer — it receives the presented certificate; see `modules/authorizers/` |
| Expiry inside the truststore | No notification, ever | Rotate on a schedule; rotation is also the inspection |
| Telling handshake failures apart | Untrusted, expired and unsupported-algorithm all answer `403` | The access log's certificate fields, which `modules/openapi-api/` records |
| Private APIs | Mutual TLS is unavailable on them | A VPC endpoint policy and a resource policy |

## Why `api_kind` rather than supporting both at once

A REST domain and an HTTP API domain are different resources, in different
services, with different mapping resources — base path mappings against one, API
mappings against the other. A domain fronting both would have two things
believing they own it.

They also differ in what they will accept, which is worth knowing before
choosing:

| | REST domain | HTTP API domain |
|---|---|---|
| Endpoint type | `REGIONAL` or `EDGE` | `REGIONAL` only, enforced by the provider |
| Security policy | Optional — **the service picks one if you do not** | `TLS_1_2` only, enforced by the provider |
| Certificate field | `regional_certificate_arn` or `certificate_arn`, and they conflict | One field |

This module always states the security policy. On a REST domain an unstated
policy is whatever AWS chose on the day, invisible in the plan and invisible in
the diff.

## The ownership verification certificate

Mutual TLS with a certificate that was **imported into ACM or issued by a
private CA** needs a second, publicly issued ACM certificate proving the domain
is yours. A publicly issued domain certificate is proof enough on its own.
Nothing in an ARN says which kind it is, so
`certificate_is_imported_or_private_ca` is asked rather than guessed, and the
pairing is checked.

That certificate takes no part in the handshake, and it must stay valid for the
life of the domain: if it expires and renewal fails, **every** update to the
domain is locked until it is replaced — including the truststore rotation you
would be trying to perform at the time.

## DNS

`hosted_zone_id` creates alias records — `A`, and `AAAA` unless turned off. With
no zone supplied the domain is configured, reports available, and resolves
nowhere; every call then fails in DNS, which looks nothing like an API Gateway
problem and is the commonest reason a new custom domain appears not to work.
`route53_records_not_created` reports it.

The alias sets `evaluate_target_health = false`, because an API Gateway domain
exposes no health check for Route 53 to evaluate and a record told to evaluate
one it cannot obtain is answered as unhealthy.

## Usage

```hcl
module "api_domain" {
  source = "./modules/custom-domain"

  domain_name     = "api.example.com"
  api_kind        = "REST"
  certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/11111111-2222-3333-4444-555555555555"

  security_policy = "TLS_1_2"

  mutual_tls = {
    truststore_bucket  = "<your-truststore-bucket>"
    truststore_key     = "truststore.pem"
    truststore_version = "K3nS8wS2cQ1pV0xR7tY4uI6oP9aL2mN5"
  }

  api_mappings = {
    orders = {
      api_id     = module.orders_api.rest_api_id
      stage_name = module.orders_api.stage_name
      base_path  = "orders"
    }
  }

  hosted_zone_id = "Z0123456789ABCDEFGHIJ"
  tags           = { Environment = "prod" }
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `domain_name` | `string` | — | Fully qualified domain name clients call |
| `api_kind` | `string` | — | `REST` or `HTTP` |
| `certificate_arn` | `string` | — | ACM certificate for the domain, in this region |
| `certificate_is_imported_or_private_ca` | `bool` | `false` | Whether the certificate was imported or issued by a private CA |
| `ownership_verification_certificate_arn` | `string` | `null` | ACM certificate proving domain ownership |
| `rest_endpoint_type` | `string` | `"REGIONAL"` | `REGIONAL` or `EDGE`; ignored for an HTTP API domain |
| `security_policy` | `string` | `"TLS_1_2"` | Minimum TLS version negotiated |
| `mutual_tls` | `object` | `null` | Truststore bucket, key and **required** version |
| `create_truststore_bucket` | `bool` | `false` | Whether this module creates the bucket, with versioning on |
| `truststore_bucket_kms_key_arn` | `string` | `null` | Key encrypting a bucket this module creates |
| `api_mappings` | `map(object)` | `{}` | APIs served under this domain, with base paths |
| `hosted_zone_id` | `string` | `null` | Zone the alias records are created in |
| `create_ipv6_record` | `bool` | `true` | Whether an `AAAA` alias is created too |
| `tags` | `map(string)` | `{}` | Tags applied to every resource |

## Outputs

| Name | Description |
|---|---|
| `domain_name` | The custom domain name |
| `api_kind` | Which kind of API this domain fronts |
| `domain_arn` | ARN of the domain name resource |
| `endpoint_type` | Endpoint type in force |
| `security_policy` | Minimum TLS version negotiated |
| `alias_target` | Target an alias record points at |
| `alias_zone_id` | Hosted zone of the alias target |
| `record_types_created` | Record types created in the caller's zone |
| `base_paths` | Base path each mapped API is served at |
| `invoke_urls` | URL each mapped API is reachable at |
| `mutual_tls_enabled` | Whether a client certificate is required |
| `truststore_uri` | Truststore the domain validates against |
| `truststore_version` | Object version actually in force |
| `truststore_bucket_created` | Whether this module created the bucket |
| `rotating_the_truststore_requires_changing_the_version` | Always true, and why the version is required |
| `certificate_revocation_not_checked` | Always true |
| `truststore_certificate_expiry_not_notified` | Always true |
| `handshake_failures_are_not_distinguished` | Always true |
| `mutual_tls_is_not_available_for_private_apis` | Always true |
| `route53_records_not_created` | True when no zone was supplied |
| `ipv6_record_not_created` | True when only an `A` record exists |
