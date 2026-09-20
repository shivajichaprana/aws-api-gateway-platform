# `http-api`

An API Gateway HTTP API with its integrations, routes, stage and access logging.

## What this module is built around

An HTTP API has **no execution logging**. A REST API writes a second stream
recording what the gateway did on the way to its answer; an HTTP API does not,
so the access log is the only place anything is ever written down about a
request, and whatever is not in the log format is not recorded anywhere.

Every access log format offered in the API Gateway console — CLF, JSON, XML and
CSV — omits `$context.integrationErrorMessage`. That is the field that separates
these three from each other:

- API Gateway is not permitted to invoke the function
- the function returned a shape the payload format does not allow
- the integration ran past its timeout

All three answer the client with `{"message":"Internal Server Error"}` and all
three look identical in the suggested formats. This module therefore treats the
log format as part of what it delivers: its own format carries
`integrationErrorMessage`, `error.message`, `error.responseType` and
`authorizer.error`, and a format supplied by the caller is **rejected at plan
time** unless it carries `integrationErrorMessage` too.

## The failures this module moves to plan time

| Configuration | Why it is refused |
|---|---|
| `stage_auto_deploy = false` with no `stage_deployment_id` | The API, its routes and its integrations are all created and correct, and every request is answered by whatever was last deployed — which on a new API is nothing |
| A route naming an integration that is not declared | A route with no target, reported as a missing map key rather than as a mistake |
| Two routes sharing one `route_key` | A route key identifies one route, so this is one route declared twice |
| CORS configured, `$default` route authorized, no unauthenticated `OPTIONS /{proxy+}` | `$default` catches the browser's preflight, a browser sends no credentials on a preflight, so every cross-origin call fails while `curl` succeeds |
| `allow_credentials` with the `*` origin | A browser refuses any response carrying credentials alongside a wildcard origin, so the pair deploys cleanly and fails only in a browser |
| `timeout_milliseconds` above 30000 | 30 seconds is the ceiling an HTTP API integration can be given; a backend allowed longer returns `504` while its own work continues and is billed |
| A greedy path variable that is not the last segment | It matches the rest of the path, so nothing after it can ever match |
| `authorization_scopes` on a route that is not `JWT` | Scopes are read from a JWT claim; anywhere else they are accepted and enforce nothing |
| `vpc_link_id` without `VPC_LINK`, or `VPC_LINK` on a Lambda integration | A connection that is configured and not used |

## What it reports rather than silently deciding

Four outputs exist because the alternative is doing something quieter than the
caller asked for:

- `lambda_permissions_not_managed` — routes whose function is in another account
  or region, or where grants are managed elsewhere. Each answers with an
  internal server error until granted, and the body is the same as every other
  integration failure.
- `routes_matching_unlisted_paths` — any `$default` route. It catches every
  request no other route matched, so a misspelled path reaches a backend instead
  of returning `404`.
- `default_endpoint_enabled` — whether the generated `execute-api` endpoint still
  answers. While it does, a client can reach the API without passing through a
  custom domain, and therefore without anything attached to the domain rather
  than to the stage.
- `integration_cors_headers_discarded` — true whenever CORS is configured, because
  API Gateway then answers preflight requests itself and discards any CORS
  headers the integration returns.

## Two defaults worth knowing

**`payload_format_version` is always sent, and always as `2.0` unless asked
otherwise.** The AWS provider defaults this field to `1.0` while the console
creates Lambda integrations at `2.0`. A function written against a
console-created API and then rebuilt in Terraform would have the event shape
changed underneath it — the request context moves and `rawPath` is not
populated — so the module states the version rather than inheriting a default
that disagrees with the one the function was written for.

**Invocation grants are written here, per route.** Creating an integration in
the console attaches the grant for you; creating one through the API, and
therefore through Terraform, does not. The source ARN for the `$default` route
has a different shape from every other route — it carries no method and no path,
because it matches all of them — so deriving it the usual way produces a grant
that can never match, whose symptom is the same internal server error as having
no grant at all.

## Usage

```hcl
module "orders_api" {
  source = "../../modules/http-api"

  name        = "orders"
  description = "Order service front door"

  integrations = {
    orders = {
      type                   = "AWS_PROXY"
      uri                    = "arn:aws:lambda:us-east-1:123456789012:function:orders"
      payload_format_version = "2.0"
      timeout_milliseconds   = 10000
    }
  }

  routes = {
    list-orders = {
      route_key       = "GET /orders"
      integration_key = "orders"
    }
    get-order = {
      route_key              = "GET /orders/{id}"
      integration_key        = "orders"
      throttling_rate_limit  = 200
      throttling_burst_limit = 100
    }
  }

  cors_configuration = {
    allow_origins = ["https://app.example.com"]
    allow_methods = ["GET", "OPTIONS"]
  }

  access_log_retention_days = 90
  access_log_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/00000000-1111-2222-3333-444444444444"
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | API name and the stem of every derived name |
| `description` | `string` | `null` | Description recorded on the API |
| `integrations` | `map(object)` | `{}` | Backends the API can reach, keyed by a short stable name |
| `routes` | `map(object)` | `{}` | Routes exposed by the API, keyed by a short stable name |
| `cors_configuration` | `object` | `null` | Cross-origin configuration; null when the API is not called from a browser |
| `stage_name` | `string` | `"$default"` | Stage serving the API |
| `stage_auto_deploy` | `bool` | `true` | Redeploy the stage whenever the API changes |
| `stage_deployment_id` | `string` | `null` | Deployment served when `stage_auto_deploy` is off |
| `default_throttling_burst_limit` | `number` | `500` | Stage-wide burst ceiling |
| `default_throttling_rate_limit` | `number` | `1000` | Stage-wide steady-state ceiling, requests per second |
| `detailed_metrics_enabled` | `bool` | `false` | Publish per-route CloudWatch metrics |
| `access_log_group_name` | `string` | `null` | Existing log group; null creates one |
| `access_log_retention_days` | `number` | `90` | Retention for a group this module creates |
| `access_log_kms_key_arn` | `string` | `null` | Customer-managed key for a group this module creates |
| `access_log_format` | `string` | `null` | Access log format; null uses this module's own |
| `disable_default_endpoint` | `bool` | `false` | Refuse requests to the generated `execute-api` endpoint |
| `manage_lambda_permissions` | `bool` | `true` | Grant API Gateway permission to invoke the functions behind `AWS_PROXY` routes |
| `tags` | `map(string)` | `{}` | Additional tags |

### `integrations` fields

| Field | Type | Default | Notes |
|---|---|---|---|
| `type` | `string` | required | `AWS_PROXY` or `HTTP_PROXY` |
| `uri` | `string` | required | Function ARN, `https://` URL, listener ARN or Cloud Map service ARN |
| `integration_method` | `string` | `null` | Required for `HTTP_PROXY`, refused for `AWS_PROXY` |
| `payload_format_version` | `string` | `"2.0"` | `1.0` or `2.0` |
| `timeout_milliseconds` | `number` | `30000` | 50–30000 |
| `connection_type` | `string` | `"INTERNET"` | `INTERNET` or `VPC_LINK` |
| `vpc_link_id` | `string` | `null` | Required for, and only for, `VPC_LINK` |
| `request_parameters` | `map(string)` | `{}` | Parameter mappings applied to the request |
| `description` | `string` | `null` | Description recorded on the integration |

### `routes` fields

| Field | Type | Default | Notes |
|---|---|---|---|
| `route_key` | `string` | required | `$default`, or a method and absolute path |
| `integration_key` | `string` | required | Must name a declared integration |
| `authorization_type` | `string` | `"NONE"` | `NONE`, `JWT`, `AWS_IAM` or `CUSTOM` |
| `authorizer_id` | `string` | `null` | Required for, and only for, `JWT` and `CUSTOM` |
| `authorization_scopes` | `list(string)` | `[]` | `JWT` routes only |
| `throttling_burst_limit` | `number` | `null` | Falls back to the stage default |
| `throttling_rate_limit` | `number` | `null` | Falls back to the stage default |
| `detailed_metrics_enabled` | `bool` | `null` | Falls back to the stage default |

## Outputs

| Name | Description |
|---|---|
| `api_id` | Identifier of the HTTP API |
| `api_arn` | ARN of the HTTP API |
| `api_execution_arn` | Execution ARN, the prefix an invocation grant is built from |
| `api_endpoint` | Generated `execute-api` endpoint, or null once disabled |
| `stage_name` | Name of the deployed stage |
| `invoke_url` | Base URL clients call |
| `route_keys` | Route keys served, by route name |
| `integration_ids` | Integration identifiers, by integration name |
| `access_log_group_name` | Log group receiving access logs |
| `access_log_format` | Access log format in force |
| `effective_route_settings` | Throttling and metrics in force per route key |
| `lambda_permissions_not_managed` | Routes this module did not grant, and why |
| `routes_matching_unlisted_paths` | Routes declared with the `$default` key |
| `default_endpoint_enabled` | Whether the generated endpoint still answers |
| `integration_cors_headers_discarded` | True when CORS is configured |
