# authorizers

JWT and Lambda authorizers for an HTTP API, and a bundled authorizer function
that requires every scope a route asks for.

## The thing worth reading first

**API Gateway's route-level `authorization_scopes` is ANY-of, not all-of.**

A route that lists `orders:read`, `orders:write` and `orders:admin` is granted
to a token holding any one of the three. Written down, that list looks like a
requirement; enforced, it is an alternatives list. Nothing reports the
difference — the route works, the authorizer reports healthy, and a token
holding only the weakest scope reaches an endpoint the list was written to
protect.

Two things follow, and this module does both:

- A JWT authorizer is the right tool when the scopes on a route really are
  alternatives, or when there are none. It is cheap, it adds no function to the
  request path, and it re-checks the token on every request.
- A **Lambda authorizer declared with `scope_enforcement`** is the tool when the
  list is a requirement. The bundled function requires *all* of the scopes
  configured for the route, and `scope_enforced_routes` reports exactly which
  routes are enforced that way, so the two readings are never confused for one
  another.

## The failures this module moves to plan time

| What is configured | What happens without the guard |
|---|---|
| A cached authorizer with per-route scopes and no `$context.routeKey` identity source | A decision made for one route is replayed for every other route the same token reaches. The scopes on those routes stop being consulted. Passes any test that exercises one route. |
| `result_ttl_in_seconds` left unset | The provider supplies 300 by itself, and *which* configurations it does that for changed inside the version range this repository pins. The same file yields a cached authorizer on one resolved provider and an uncached one on another. |
| A JWT authorizer with no audience | Accepted by the provider, refused by API Gateway. An audience is the only thing tying a token to this API rather than to anything else the issuer signs. |
| An issuer pasted as its discovery or JWKS URL | API Gateway appends the discovery path itself, so the URL resolves to nothing and every request is refused with a message about the token. |
| `enable_simple_responses` with payload format 1.0 | A 1.0 authorizer answers with an IAM policy and has no simple form. |
| A Lambda authorizer with caching and no identity source | The identity sources *are* the cache key. With none there is nothing to key on. |
| One name used by both a JWT and a Lambda authorizer | The merged lookup silently keeps one, and it decides the requests the other was written for. |

## The invoke grant

An authorizer's execute-api ARN carries **no stage, no method and no path**:

```
arn:aws:execute-api:<region>:<account>:<api-id>/authorizers/<authorizer-id>
```

A route's does. Deriving the authorizer's grant the way a route's is derived
produces a grant that can never match, and a grant that never matches fails
exactly like no grant at all — an internal server error, with nothing in the
access log naming permission as the cause. `authorizer_source_arns` reports the
value each grant was actually scoped to.

## Caching, and what it does to expiry

A JWT authorizer verifies the token in the gateway on every request, so a token
stops working the moment it expires.

A Lambda authorizer with `result_ttl_in_seconds` greater than zero does not. Its
answer is cached against the identity sources, so a request made one second
before a token expires is answered from that cache for the rest of the window,
and so is every later request carrying the same token. `result_ttl_in_seconds`
defaults to `0` here for that reason: the cost is an invocation per request, and
the benefit is that a token's own expiry is the thing that ends access.

If caching is turned on and the authorizer decides differently per route, add
`$context.routeKey` to `identity_sources`. The module refuses the combination
without it.

## The bundled function

Deployed for any Lambda authorizer declaring `scope_enforcement`. Standard
library only — nothing to resolve, pin or patch — and it:

- **verifies the signature**, RSASSA-PKCS1-v1_5 against the issuer's published
  keys. Decoding a token is not verifying it: the payload of an unverified token
  is whatever the caller typed.
- **takes the algorithm from the key, never from the token.** A verifier that
  reads the token's own `alg` can be handed `none`, or `HS256` keyed on the RSA
  public key — which is public. Both produce tokens that verify. When a key
  publishes no `alg`, RS256 is assumed and a token claiming anything else is
  refused rather than allowed to revise the assumption.
- **selects the key by `kid`**, and refreshes once if the id is unknown. `kid`
  is chosen by whoever made the token, so falling back to another key when the
  named one is missing accepts a token naming a key that was never published.
- **requires `exp`.** A token with no expiry never expires, and a check that
  only looks when the claim is present treats the most dangerous token it can
  be handed as the one with nothing to object to.
- **reads `client_id` when `aud` is absent**, because an access token names the
  client there and carries no `aud` at all.
- **denies on every failure**, including an unreachable key set and an
  unexpected exception. The reason is written to the function's log group; the
  caller is told only that it was denied.

## Usage

```hcl
module "authorizers" {
  source = "./modules/authorizers"

  api_id            = module.http_api.api_id
  api_execution_arn = module.http_api.api_execution_arn
  name_prefix       = "orders-api"

  jwt_authorizers = {
    workforce = {
      cognito_user_pool_id = "us-east-1_ab12CD34e"
      audience             = ["1example23456789abcdefghij"]
    }
  }

  lambda_authorizers = {
    partners = {
      identity_sources      = ["$request.header.Authorization", "$context.routeKey"]
      result_ttl_in_seconds = 300

      scope_enforcement = {
        issuer   = "https://issuer.example.invalid/tenant"
        audience = ["partner-api"]

        # Every scope listed for a route must be present. A route with no
        # entry is denied, so adding one without deciding its scopes fails
        # closed.
        required_scopes = {
          "GET /orders"       = ["orders:read"]
          "POST /orders"      = ["orders:read", "orders:write"]
          "DELETE /orders/{id}" = ["orders:write", "orders:admin"]
        }
      }
    }
  }
}
```

A route then names the authorizer by key rather than by identifier, and the
caller resolves it:

```hcl
routes = {
  list-orders = {
    route_key          = "GET /orders"
    integration_key    = "orders"
    authorization_type = "CUSTOM"
    authorizer_id      = module.authorizers.authorizer_ids["partners"]
  }
}
```

### Do not add `depends_on` to either module call

The API module produces the id this module needs, and this module produces the
ids its routes need. Terraform follows the individual values and derives the
order from them. `depends_on` on a module call is not a hint about one value: it
makes everything inside that module wait for everything in the target, which
closes the two calls into a cycle Terraform refuses to plan.

## Inputs

| Name | Type | Default | Why you would change it |
|---|---|---|---|
| `api_id` | `string` | — | The API these authorizers belong to. An authorizer cannot be shared with another API. |
| `api_execution_arn` | `string` | — | Stem of the invoke grant. Taken as an input so the grant and the API can never be built from different values. |
| `name_prefix` | `string` | — | Stem of every derived name. Capped at 28 characters by the IAM role name a bundled function needs. |
| `jwt_authorizers` | `map(object)` | `{}` | Token verification inside the gateway. |
| `lambda_authorizers` | `map(object)` | `{}` | A function decides, either one you own or the bundled one. |
| `manage_lambda_permissions` | `bool` | `true` | Turn off only when the invoke grants are made elsewhere. What is left ungranted is reported. |
| `tags` | `map(string)` | `{}` | Tags for resources created here. |

### `jwt_authorizers` entries

| Field | Type | Default | Notes |
|---|---|---|---|
| `audience` | `list(string)` | — | At least one. This is what ties a token to this API. |
| `issuer` | `string` | `null` | Exactly one of this or `cognito_user_pool_id`. |
| `cognito_user_pool_id` | `string` | `null` | The issuer URL is derived from the pool, which already names its region. |
| `identity_source` | `string` | `$request.header.Authorization` | One header. A request without it is refused before anything runs. |

### `lambda_authorizers` entries

| Field | Type | Default | Notes |
|---|---|---|---|
| `function_arn` | `string` | `null` | Exactly one of this or `scope_enforcement`. |
| `identity_sources` | `list(string)` | `["$request.header.Authorization"]` | Also the cache key when caching is on. |
| `result_ttl_in_seconds` | `number` | `0` | Always sent. `0` means the token's own expiry ends access. |
| `payload_format_version` | `string` | `"2.0"` | Required by API Gateway; the provider does not supply it. |
| `enable_simple_responses` | `bool` | `true` | Needs format `2.0`. |
| `scope_enforcement` | `object` | `null` | Deploys the bundled function. |

### `scope_enforcement`

| Field | Type | Default | Notes |
|---|---|---|---|
| `issuer` | `string` | — | Issuer identifier, not its discovery URL. |
| `audience` | `list(string)` | — | At least one. |
| `required_scopes` | `map(list(string))` | `{}` | Keyed by route key. **All** listed scopes are required. |
| `unlisted_route_action` | `string` | `"deny"` | A route with no entry, and no `$default` entry, is refused. |
| `jwks_cache_seconds` | `number` | `600` | Above a day a rotated-out key stays trusted. |
| `clock_skew_seconds` | `number` | `60` | Tolerance for disagreeing clocks, not a way to extend a token. |
| `memory_size` | `number` | `256` | |
| `timeout_seconds` | `number` | `5` | Spent inside the request, before the integration is reached. |
| `log_retention_days` | `number` | `90` | |
| `log_kms_key_arn` | `string` | `null` | The key policy must already admit CloudWatch Logs. |

## Outputs

| Name | What it answers |
|---|---|
| `authorizer_ids` | The map a route's `authorizer_id` is looked up in. |
| `jwt_authorizer_ids` | Identifiers of the JWT authorizers. |
| `lambda_authorizer_ids` | Identifiers of the Lambda authorizers. |
| `jwt_issuers` | What each issuer resolved to, including one derived from a pool id. |
| `authorizers_with_cached_results` | Which decisions outlive the token that produced them, and for how long. |
| `scope_enforced_routes` | Which routes require every scope rather than any one. |
| `authorizer_invocations_not_granted` | What this configuration did not grant. |
| `authorizer_source_arns` | What each grant was scoped to, for when one is not matching. |
| `scope_enforcement_function_names` | Functions built here. |
| `scope_enforcement_log_groups` | Where a denial's reason is recorded. |
