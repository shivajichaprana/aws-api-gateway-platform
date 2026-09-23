# A custom domain name, and optionally the client certificate requirement that
# only a custom domain can carry.
#
# Mutual TLS is not a setting on an API. It belongs to the domain name clients
# reach the API through, which is why it appears here and not in either API
# module -- and why enabling it is bound up with two things that are easy to get
# right separately and wrong together: the domain has to be regional, and the
# API's own generated endpoint has to stop answering.
#
# The second is the one that is invisible. Turning mutual TLS on makes a client
# certificate mandatory at this domain, and changes nothing at all about the
# execute-api endpoint API Gateway generated for the API. Anything still holding
# that URL keeps working, without a certificate, and every check made against
# the domain passes.

locals {
  is_rest = var.api_kind == "REST"
  is_http = var.api_kind == "HTTP"

  mutual_tls_enabled = var.mutual_tls != null

  # An HTTP API domain is regional whatever is asked for -- the provider accepts
  # no other endpoint type -- so the effective type is derived rather than left
  # as two inputs that can disagree.
  effective_endpoint_type = local.is_http ? "REGIONAL" : var.rest_endpoint_type

  # Mutual TLS exists on a regional domain only, and requires TLS 1.2.
  mutual_tls_on_an_edge_domain   = local.mutual_tls_enabled && local.effective_endpoint_type != "REGIONAL"
  mutual_tls_below_tls_12        = local.mutual_tls_enabled && var.security_policy != "TLS_1_2"
  mutual_tls_without_ownership   = local.mutual_tls_enabled && var.certificate_is_imported_or_private_ca && var.ownership_verification_certificate_arn == null
  ownership_without_mutual_tls   = !local.mutual_tls_enabled && var.ownership_verification_certificate_arn != null
  truststore_bucket_not_declared = var.create_truststore_bucket && !local.mutual_tls_enabled

  # Gated on the truststore being declared as well as requested: the bucket's
  # name comes from that declaration, so creating it without one would fail on a
  # null lookup instead of at the check written to report the mistake.
  create_truststore_bucket = var.create_truststore_bucket && local.mutual_tls_enabled

  truststore_uri = local.mutual_tls_enabled ? "s3://${var.mutual_tls.truststore_bucket}/${var.mutual_tls.truststore_key}" : null

  # Mappings are split by kind, because a base path mapping and an API mapping
  # are separate resources in separate services. Both are driven from one input
  # so a caller declares a route once.
  rest_mappings = local.is_rest ? var.api_mappings : {}
  http_mappings = local.is_http ? var.api_mappings : {}

  mappings_at_the_domain_root = sort([
    for key, mapping in var.api_mappings : key if mapping.base_path == ""
  ])

  # The alias target differs between the two kinds and is resolved once here, so
  # the record below reads one value rather than branching again. The HTTP form
  # carries it inside a nested block, which cannot be reached through a splat
  # without indexing a list of lists, so the resource object is taken whole and
  # guarded against being absent.
  http_domain = one(aws_apigatewayv2_domain_name.http[*])

  alias_target_name = (local.is_rest
    ? one(aws_api_gateway_domain_name.rest[*].regional_domain_name)
    : (local.http_domain == null ? null : local.http_domain.domain_name_configuration[0].target_domain_name)
  )

  alias_zone_id = (local.is_rest
    ? one(aws_api_gateway_domain_name.rest[*].regional_zone_id)
    : (local.http_domain == null ? null : local.http_domain.domain_name_configuration[0].hosted_zone_id)
  )

  create_records       = var.hosted_zone_id != null
  create_ipv6_record   = local.create_records && var.create_ipv6_record
  record_types         = local.create_records ? (local.create_ipv6_record ? toset(["A", "AAAA"]) : toset(["A"])) : toset([])
  bucket_key_enabled   = var.truststore_bucket_kms_key_arn != null
  bucket_sse_algorithm = local.bucket_key_enabled ? "aws:kms" : "AES256"
}

# Every cross-parameter check lives here rather than on the domain, for the
# reason recorded in modules/http-api/ and modules/openapi-api/: a precondition
# becomes part of its resource's dependencies, and the mappings and records below
# all need the domain.
resource "terraform_data" "domain" {
  input = var.domain_name

  lifecycle {
    precondition {
      condition     = !local.mutual_tls_on_an_edge_domain
      error_message = "Mutual TLS requires a regional custom domain name. An edge-optimized domain terminates TLS in the CloudFront distribution API Gateway owns, which cannot ask a client for a certificate -- so the configuration is refused rather than accepted and ignored."
    }

    precondition {
      condition     = !local.mutual_tls_below_tls_12
      error_message = "Mutual TLS requires the TLS_1_2 security policy. TLS_1_0 is offered for a domain that has to serve old clients, and that is exactly the domain mutual TLS cannot be added to."
    }

    precondition {
      condition     = !local.mutual_tls_without_ownership
      error_message = "This certificate was declared as imported or private-CA, and mutual TLS with one of those needs ownership_verification_certificate_arn as well: a publicly issued ACM certificate proves the domain is yours, an imported one does not. Keep that certificate valid -- if it expires, every update to this domain is locked until it is replaced, including the truststore update you would be trying to make."
    }

    precondition {
      condition     = !local.ownership_without_mutual_tls
      error_message = "ownership_verification_certificate_arn is set and mutual TLS is not enabled. It is only used to verify domain ownership for mutual TLS, so here it is a certificate that has to be kept valid for nothing."
    }

    precondition {
      condition = length(local.mappings_at_the_domain_root) <= 1
      error_message = format(
        "These mappings all leave base_path empty, which serves an API at the root of the domain: %s. One may; the second is refused once the first exists, leaving the domain with some of its mappings.",
        join(", ", local.mappings_at_the_domain_root)
      )
    }

    precondition {
      condition     = !local.truststore_bucket_not_declared
      error_message = "create_truststore_bucket is set and mutual_tls is null. The bucket would be created, versioned, and hold nothing that anything reads."
    }
  }
}

# ---------------------------------------------------------------------------
# Truststore bucket
# ---------------------------------------------------------------------------

# Versioning is on and is not a variable. An object version IS the unit of a
# truststore rotation: API Gateway is pointed at a specific version, and a
# bucket without versioning has none to point at.
resource "aws_s3_bucket" "truststore" {
  count = local.create_truststore_bucket ? 1 : 0

  bucket = var.mutual_tls.truststore_bucket
  tags   = var.tags
}

resource "aws_s3_bucket_ownership_controls" "truststore" {
  count = local.create_truststore_bucket ? 1 : 0

  bucket = one(aws_s3_bucket.truststore[*].id)

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "truststore" {
  count = local.create_truststore_bucket ? 1 : 0

  bucket = one(aws_s3_bucket.truststore[*].id)

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "truststore" {
  count = local.create_truststore_bucket ? 1 : 0

  bucket = one(aws_s3_bucket.truststore[*].id)

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "truststore" {
  count = local.create_truststore_bucket ? 1 : 0

  bucket = one(aws_s3_bucket.truststore[*].id)

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.bucket_sse_algorithm
      kms_master_key_id = var.truststore_bucket_kms_key_arn
    }

    bucket_key_enabled = local.bucket_key_enabled
  }
}

data "aws_iam_policy_document" "truststore" {
  count = local.create_truststore_bucket ? 1 : 0

  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    actions = ["s3:*"]

    resources = [
      one(aws_s3_bucket.truststore[*].arn),
      "${one(aws_s3_bucket.truststore[*].arn)}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "truststore" {
  count = local.create_truststore_bucket ? 1 : 0

  bucket = one(aws_s3_bucket.truststore[*].id)
  policy = one(data.aws_iam_policy_document.truststore[*].json)

  depends_on = [aws_s3_bucket_public_access_block.truststore]
}

# ---------------------------------------------------------------------------
# REST domain
# ---------------------------------------------------------------------------

resource "aws_api_gateway_domain_name" "rest" {
  count = local.is_rest ? 1 : 0

  domain_name = var.domain_name

  # A regional domain takes the regional attribute and an edge one takes the
  # other. They are separate fields that conflict, and a certificate given to
  # the wrong one is reported as a conflict rather than as a mismatch.
  regional_certificate_arn = local.effective_endpoint_type == "REGIONAL" ? var.certificate_arn : null
  certificate_arn          = local.effective_endpoint_type == "EDGE" ? var.certificate_arn : null

  security_policy = var.security_policy

  ownership_verification_certificate_arn = var.ownership_verification_certificate_arn

  endpoint_configuration {
    types = [local.effective_endpoint_type]
  }

  # toset() on both branches: a conditional whose arms are an empty list and a
  # one-element list of an object have no common type unless both are sets.
  dynamic "mutual_tls_authentication" {
    for_each = local.mutual_tls_enabled ? toset(["enabled"]) : toset([])

    content {
      truststore_uri     = local.truststore_uri
      truststore_version = var.mutual_tls.truststore_version
    }
  }

  tags = var.tags

  depends_on = [terraform_data.domain]
}

resource "aws_api_gateway_base_path_mapping" "rest" {
  for_each = local.rest_mappings

  domain_name = one(aws_api_gateway_domain_name.rest[*].domain_name)
  api_id      = each.value.api_id
  stage_name  = each.value.stage_name

  # An empty base path is the domain root. The provider sends the empty string,
  # which API Gateway records as the reserved "(none)" mapping.
  base_path = each.value.base_path == "" ? null : each.value.base_path
}

# ---------------------------------------------------------------------------
# HTTP domain
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_domain_name" "http" {
  count = local.is_http ? 1 : 0

  domain_name = var.domain_name

  domain_name_configuration {
    certificate_arn = var.certificate_arn

    # Both are required by the provider and both accept exactly one value here,
    # so the constraints mutual TLS imposes are the only ones available anyway.
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"

    ownership_verification_certificate_arn = var.ownership_verification_certificate_arn
  }

  dynamic "mutual_tls_authentication" {
    for_each = local.mutual_tls_enabled ? toset(["enabled"]) : toset([])

    content {
      truststore_uri     = local.truststore_uri
      truststore_version = var.mutual_tls.truststore_version
    }
  }

  tags = var.tags

  depends_on = [terraform_data.domain]
}

resource "aws_apigatewayv2_api_mapping" "http" {
  for_each = local.http_mappings

  domain_name = one(aws_apigatewayv2_domain_name.http[*].domain_name)
  api_id      = each.value.api_id
  stage       = each.value.stage_name

  api_mapping_key = each.value.base_path == "" ? null : each.value.base_path
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

# An alias rather than a CNAME, so the apex of a zone can be used and so the
# record costs nothing to resolve. evaluate_target_health is false because an
# API Gateway domain exposes no health check for Route 53 to evaluate, and a
# record set to evaluate one it cannot get is answered as unhealthy.
resource "aws_route53_record" "alias" {
  for_each = local.record_types

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = each.key

  alias {
    name                   = local.alias_target_name
    zone_id                = local.alias_zone_id
    evaluate_target_health = false
  }
}
