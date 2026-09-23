# OpenAPI documents

Each file here is a complete API. API Gateway imports it and builds every
resource, method, integration, validator and gateway response from it, so the
document is the source of truth for routing and Terraform declares no paths at
all.

| Document | Serves | Integration | Notes |
| --- | --- | --- | --- |
| `orders-api.yaml` | `/orders`, `/orders/{orderId}`, `/health` | Lambda proxy, plus one mock for the probe | Signature Version 4 over the whole document; `/health` opts out and is reported |

## Why the document rather than the resources

The alternative is what `modules/rest-api/` does: declare methods in Terraform
and let it build the resource tree. Both are legitimate and they are mutually
exclusive per API, because mixing them means two things believe they own the
same resources and each apply removes what the other created.

An imported document wins when the specification already exists — when it is
reviewed, published to callers, or generated from the service that implements
it. Terraform-declared methods win when there is no document and the API is
small. What is not available is half of each.

## Conventions, all of them enforced

These are not style preferences. Each one exists because breaking it produces an
API that imports cleanly, reports healthy, and does not work.

**Every operation carries `x-amazon-apigateway-integration`.** Without it the
method is created with nothing behind it. The route appears in the console, the
import reports success, and the call answers 500. The importing module refuses
a document with an operation that has no integration, and the import itself is
run with warnings treated as failures so a misspelled extension key stops the
apply rather than being skipped.

**Every operation's authorization is deliberate.** The document-level `security`
block applies to any operation that says nothing, so the failure mode is a
signed request rather than an open one. An operation that overrides it with
`security: []` is open, and the module lists every one of those in an output —
open-by-decision and open-by-accident are the same document otherwise.

**`${...}` is a Terraform template variable.** The document is rendered before it
reaches AWS, so every `${name}` is substituted and a name that is not supplied
fails the render. That is deliberate: it means a placeholder cannot survive into
a deployed API. API Gateway's own references — `$context.requestId`,
`$input.json(...)`, `$stageVariables.x` — carry no brace after the `$` and pass
through untouched, which is why the mapping templates below are safe. A mapping
template that genuinely needs `${` must escape it as `$${`.

**Every validator that is declared is referenced.** A validator nothing points
at validates nothing, and a parameter declared without one is documentation:
the request reaches the integration with the parameter missing.

**A proxy integration is invoked with `POST`.** Always, whatever method the
caller used, because that is the integration's own call to Lambda. Writing the
caller's method there answers 500 on every request.

## Changing a document

A change here changes the API on the next apply. Two things follow from that:

1. **Removing an operation removes the route.** The import runs in overwrite
   mode, which is what makes the document authoritative. Merge mode is
   available and leaves removed operations in place, which means the document
   stops describing the API — the module reports which mode is in effect.
2. **A new document needs a new deployment.** Importing changes the API; the
   stage keeps serving the deployment it was given. The module keys the
   deployment to the rendered document so any change to it produces one, but a
   change made outside Terraform will not.

## Placeholders

| Name | Supplied from |
| --- | --- |
| `api_title` | The API's name |
| `partition` | The caller's partition |
| `aws_region` | The deployment region |
| `orders_function_arn` | ARN of the function serving the order paths |
| `integration_timeout_ms` | Integration timeout, bounded by the module |
| `disable_execute_api_endpoint` | Whether the generated endpoint answers |

No placeholder carries a credential. A document is committed, reviewed and
diffed, so anything secret belongs in the integration's own configuration.
