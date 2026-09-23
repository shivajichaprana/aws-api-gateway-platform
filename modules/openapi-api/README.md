# modules/openapi-api

A REST API whose routing comes from an OpenAPI document. API Gateway imports the
document and builds every resource, method, integration, validator and gateway
response from it; this module decides how that import is deployed and checks the
things the import does not.

## Why this is a separate module from `modules/rest-api`

An API cannot be both. `modules/rest-api/` declares methods in Terraform and
builds the resource tree from them; this module hands API Gateway a document and
lets it build the tree. Put a `body` on an API that also has
`aws_api_gateway_resource` and `aws_api_gateway_method` resources and two things
believe they own the same resources: each apply removes what the other created,
and the API alternates between two shapes with no error from either side.

The choice is per API and it is made by picking a module. An imported document
wins when the specification already exists — reviewed, published to callers, or
generated from the service that implements it. Declared methods win when there
is no document.

## Warnings are fatal here and not in the service

`fail_on_warnings` defaults to **true** in this module and to **false** in
API Gateway. Left at the service default, a document with an unrecognised
extension key, an unresolvable `$ref`, or an integration API Gateway cannot make
sense of is imported anyway — minus the parts it could not understand. The apply
succeeds. The API exists. The operation is not there, and nothing in the plan,
the state or the console says a part of the document was skipped.

That is the single most useful line in this module, and it is one word.

## What is checked before the import runs

All of it is read out of the decoded document, so each check is about what AWS
will be sent rather than about the document's text.

| Refused at plan time | Because |
|---|---|
| A `$${...}` sequence survived the render | It is imported literally — an integration URI naming no function, or a title nobody chose |
| Neither `openapi` nor `swagger` is declared | API Gateway uses that key to decide which specification it is reading |
| No paths | The import succeeds and produces an API with nothing to call |
| An operation with no `x-amazon-apigateway-integration` | It becomes a method with nothing behind it, which answers `500` — the same answer a handler that threw gives |
| A validator reference naming no declared validator | A warning at import, which with warnings fatal stops the apply after the API has been created |
| The document and the configuration disagree about the default endpoint | Both are applied, in an order visible in neither file |

## What is reported rather than refused

| Output | Why it is not an error |
|---|---|
| `operations_declaring_no_authorization` | An open liveness probe is correct; an open write path is not, and they look identical in the document |
| `functions_without_an_invocation_grant` | A function in another account, or one whose policy is owned by the stack that created it, is granted elsewhere |
| `operations_removed_from_the_document_are_left_in_place` | Merge mode is a legitimate choice with a consequence worth stating |
| `import_warnings_ignored` | Someone may need a document imported partially, once |
| `default_endpoint_enabled` | A migration window is a real thing; an indefinite one is not |
| `unreferenced_request_validators` | Harmless until someone believes the parameters are enforced |
| `document_title_differs_from_the_api_name` | The provider patches the name back, so the API is right and the document reads differently |

## The grant the import does not create

Creating an integration in the console attaches the Lambda invocation grant as a
side effect. An import does not. So an API that worked when it was clicked
together stops working when the same integration arrives from a document, and the
failure is `{"message":"Internal Server Error"}` — indistinguishable from a
handler that threw.

`lambda_integrations` is how the grant is declared, and the module cross-checks
it against the document: every integration URI of the form
`functions/<arn>/invocations` is read out of the document, and any function that
is integrated with but not granted is named in
`functions_without_an_invocation_grant`. The function list is not asked for
twice.

A grant may be narrowed with `http_method` and `path`. A path variable is
wildcarded automatically, because a grant naming a literal `{orderId}` matches a
request for that exact string and nothing else.

## Importing changes the API, not what is served

The stage serves the deployment it was given. A route added to the document
appears in the console and answers `{"message":"Not Found"}` until a deployment
captures it — which is the same trap as a hand-declared method, arriving through
a different door.

The deployment is keyed to a hash of the rendered document and of every literal
property an overwrite import can move, so any change that alters what the API is
produces one. A change made outside Terraform will not.

## Overwrite mode deletes what the document does not mention

That is what makes the document authoritative, and it is not free. An import in
overwrite mode removes literal properties of the API that the document does not
carry, and the provider reconciles only the subset of them that the Terraform
configuration also sets. The endpoint type is not in that subset — which matters
here, because a regional endpoint is a prerequisite for the custom domain that
carries mutual TLS. So this module sets `endpoint_configuration` on the resource
and the shipped document also carries
`x-amazon-apigateway-endpoint-configuration`; the two are required to agree.

## Usage

```hcl
module "orders_api" {
  source = "./modules/openapi-api"

  name        = "orders"
  description = "Order lifecycle operations"

  openapi_body = templatefile("${path.module}/openapi/orders-api.yaml", {
    api_title                    = "orders"
    partition                    = data.aws_partition.current.partition
    aws_region                   = var.aws_region
    orders_function_arn          = aws_lambda_function.orders.arn
    integration_timeout_ms       = 29000
    disable_execute_api_endpoint = true
  })

  stage_name               = "v1"
  endpoint_type            = "REGIONAL"
  disable_default_endpoint = true

  lambda_integrations = {
    orders = {
      function_name = aws_lambda_function.orders.function_name
      http_method   = "*"
      path          = "/*"
    }
  }

  stage_throttle = {
    rate_limit  = 200
    burst_limit = 400
  }

  access_log_kms_key_arn = aws_kms_key.logs.arn
  tags                   = { Environment = "prod" }
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | — | Name of the API, and the derived log group path |
| `description` | `string` | `"REST API deployed from an OpenAPI document"` | Description of the API |
| `openapi_body` | `string` | — | The rendered document |
| `endpoint_type` | `string` | `"REGIONAL"` | `REGIONAL`, `EDGE` or `PRIVATE` |
| `stage_name` | `string` | `"v1"` | Stage the deployment is served at |
| `put_rest_api_mode` | `string` | `"overwrite"` | `overwrite` or `merge` |
| `fail_on_warnings` | `bool` | `true` | Whether an import warning stops the apply |
| `disable_default_endpoint` | `bool` | `false` | Whether the generated endpoint stops answering |
| `binary_media_types` | `list(string)` | `[]` | Media types handled as binary |
| `minimum_compression_size` | `number` | `null` | Smallest response compressed |
| `lambda_integrations` | `map(object)` | `{}` | Invocation grants for the document's functions |
| `stage_throttle` | `object` | `null` | Stage-wide rate and burst ceiling |
| `metrics_enabled` | `bool` | `true` | Per-method CloudWatch metrics |
| `xray_tracing_enabled` | `bool` | `true` | X-Ray tracing on the stage |
| `access_log_retention_days` | `number` | `90` | Retention for the access log group |
| `access_log_kms_key_arn` | `string` | `null` | Key encrypting the access log group |
| `log_client_certificate_fields` | `bool` | `true` | Log the presented certificate's subject, issuer, serial and expiry |
| `tags` | `map(string)` | `{}` | Tags applied to every resource |

## Outputs

| Name | Description |
|---|---|
| `rest_api_id` | Identifier of the API |
| `rest_api_arn` | ARN of the API |
| `execution_arn` | Prefix an invocation grant is built from |
| `root_resource_id` | Root resource API Gateway created |
| `stage_name` | Deployed stage |
| `stage_arn` | Stage ARN, for a web ACL association or a base path mapping |
| `invoke_url` | Generated execute-api URL for the stage |
| `deployment_id` | Deployment the stage is serving |
| `document_sha1` | Hash of the rendered document behind this deployment |
| `document_title` | Title the document declares |
| `operations` | Every operation the document declares |
| `operation_count` | Number of operations |
| `access_log_group_name` | Log group receiving access logs |
| `access_log_format` | Access log format in use |
| `operations_declaring_no_authorization` | Operations reachable without credentials |
| `document_requires_authorization` | Whether a top-level requirement exists |
| `functions_the_document_integrates_with` | Function names read out of the document |
| `functions_without_an_invocation_grant` | Integrated with, not granted here |
| `invocation_source_arns` | Source ARN each grant was scoped to |
| `operations_removed_from_the_document_are_left_in_place` | True in merge mode |
| `import_warnings_ignored` | True when warnings are not fatal |
| `default_endpoint_enabled` | True while the generated endpoint answers |
| `unreferenced_request_validators` | Validators nothing points at |
| `document_title_differs_from_the_api_name` | Document and resource read differently |
| `execution_logging_not_configured` | Access logging only |
| `client_certificate_fields_logged` | Whether certificate fields are recorded |
