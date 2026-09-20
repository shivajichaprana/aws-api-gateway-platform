# aws-api-gateway-platform

Terraform for putting an API in front of a workload on AWS: HTTP APIs with
routes and stages, authorizers, usage plans and throttling, WAF protection, and
an OpenAPI-driven deployment path with a custom domain.

## Why this needs a platform rather than a resource

An API Gateway API is easy to create and hard to see. Almost everything that
goes wrong with one is accepted by the service, deployed without an error, and
then returns a status code that does not name its cause:

| What happens | What you see |
|---|---|
| The stage was never told to deploy changes | Routes exist in the console; requests get `{"message":"Not Found"}` |
| API Gateway may not invoke the integration | `{"message":"Internal Server Error"}` and nothing else |
| The payload format the integration expects is not the one it is sent | A handler that throws, or a `200` carrying an error body |
| A catch-all route is present | A misspelled path reaches the backend instead of returning `404` |
| CORS is configured and the backend also sets CORS headers | The backend's headers are discarded; the browser still refuses |
| The integration takes longer than the API's own ceiling | `504` to the client while the work continues, and is billed |

None of these produce a failed `terraform apply`. The purpose of this repository
is to move as many of them as possible to plan time, and to make the rest
visible in a place an operator will actually look.

## Repository layout

| Path | Contents |
|---|---|
| `versions.tf` | Terraform and provider version constraints |
| `providers.tf` | Regional provider and default tags |
| `variables.tf` | Root inputs |
| `modules/http-api/` | HTTP API, routes, stage and access logging |
| `modules/authorizers/` | JWT and Lambda request authorizers (planned) |
| `modules/rest-api/` | Usage plans, API keys and throttling (planned) |
| `openapi/` | OpenAPI documents imported into the API (planned) |

## Getting started

```bash
terraform init
terraform plan
terraform apply
```

The root configuration deploys one HTTP API with its stage, its access log group
and a customer-managed key for that group. It ships with **no integrations and
no routes**, because every integration names a function or an endpoint owned
outside this configuration and a placeholder default would deploy an API
pointing at an account that does not exist. Supply them:

```hcl
api_name = "orders"

api_integrations = {
  orders = {
    type                 = "AWS_PROXY"
    uri                  = "arn:aws:lambda:us-east-1:123456789012:function:orders"
    timeout_milliseconds = 10000
  }
}

api_routes = {
  list-orders = {
    route_key       = "GET /orders"
    integration_key = "orders"
  }
  get-order = {
    route_key       = "GET /orders/{id}"
    integration_key = "orders"
  }
}

api_cors_configuration = {
  allow_origins = ["https://app.example.com"]
  allow_methods = ["GET", "OPTIONS"]
}
```

To consume a module on its own, pin to a tag. The module interfaces in this
repository are versioned, and `main` is not a stable interface.

```hcl
module "orders_api" {
  source = "github.com/<your-github-org>/aws-api-gateway-platform//modules/http-api?ref=v1.0.0"
  # ...
}
```

## Routing and diagnostics

Two things about an HTTP API decide how most of its problems are experienced.

**Route matching is by priority, not by declaration order.** A route with a
greedy path variable outranks the `$default` catch-all, which is what makes an
`OPTIONS /{proxy+}` route the documented way to let browser preflight requests
past an authorizer. Declaring a `$default` route at all means a misspelled path
reaches a backend rather than returning `404`, so
[`modules/http-api`](modules/http-api) reports every one of them in an output
instead of treating it as ordinary.

**The access log is the only diagnostic surface there is.** An HTTP API has no
execution logging, and every log format the console offers omits the field that
names the cause of a `5xx`. The module ships a format that carries it and
refuses a supplied format that does not. See
[`modules/http-api/README.md`](modules/http-api/README.md) for what each field
distinguishes.

## Validation

No pipeline runs in this repository yet. Until one does, changes are checked
with `terraform fmt`, `terraform validate` and a reading of the plan against the
module's own preconditions.

## Design principles

- **Refuse at plan time what would otherwise fail silently.** A configuration
  that cannot work is rejected with the reason, rather than applied and left to
  be discovered from a status code.
- **The diagnostic surface is part of the deliverable.** An HTTP API has no
  execution logging at all, so the access log format is the only place a cause
  is ever written down. It is treated as a contract, not a preference.
- **Report what could not be done rather than doing something else.** Where a
  configuration asks for something outside this deployment's reach, the module
  says so in an output instead of silently narrowing the request.
- **Placeholders only.** Account identifiers, domains and ARNs in examples are
  documentation values. Nothing here is written against a real account.
- **Least privilege by construction.** Invocation grants name the route that
  uses them, not the API as a whole.

## License

MIT. See [LICENSE](LICENSE).
