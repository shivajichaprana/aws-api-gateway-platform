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
| `modules/http-api/` | HTTP API, routes, stage and access logging (planned) |
| `modules/authorizers/` | JWT and Lambda request authorizers (planned) |
| `modules/rest-api/` | Usage plans, API keys and throttling (planned) |
| `openapi/` | OpenAPI documents imported into the API (planned) |

## Getting started

```hcl
module "orders_api" {
  source = "github.com/<your-github-org>/aws-api-gateway-platform//modules/http-api?ref=v1.0.0"
  # ...
}
```

Pin every consumer to a tag. The module interfaces in this repository are
versioned, and `main` is not a stable interface.

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
