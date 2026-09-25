# Authorization model

Who is allowed to call what, how that decision is reached, and which readings of
a configuration differ from what it enforces.

[`modules/authorizers`](../modules/authorizers/README.md) documents the inputs.
This document is about the model those inputs express.

## The sentence this whole document exists for

**API Gateway's route-level `authorization_scopes` is ANY-of, not all-of.**

```hcl
api_routes = {
  delete-order = {
    route_key            = "DELETE /orders/{id}"
    authorization_type   = "JWT"
    authorizer_key       = "workforce"
    authorization_scopes = ["orders:write", "orders:admin"]
  }
}
```

Written down, that reads as a requirement: a caller needs write *and* admin. As
enforced, it is an alternatives list: a token holding `orders:write` alone is
granted. Nothing anywhere reports the difference. The route works, the
authorizer reports healthy, the metrics are clean, and the weakest scope in the
list is the one that decides access.

There is no setting that changes it. If the list is a requirement, the decision
has to be made somewhere that can require things — which means a function.

## Choosing an authorizer

| | JWT authorizer | Lambda authorizer |
|---|---|---|
| Where the decision is made | Inside the gateway | In a function you or this repository deploy |
| Scope semantics | ANY-of, per route | Whatever the function implements |
| Cost per request | None | One invocation |
| Latency added | Negligible | Function duration, inside the caller's request |
| Caching | None; the token is re-checked every time | `result_ttl_in_seconds`, default `0` here |
| Effect of token expiry | Immediate | Immediate only when caching is off |
| Custom claims, tenancy, revocation, certificate inspection | No | Yes |

The choice is not about cost. Use a JWT authorizer when the scopes on a route
genuinely are alternatives, or when there are none; it adds nothing to the
request path and re-verifies on every request. Use a Lambda authorizer when the
list is a requirement, when a decision needs a claim API Gateway does not
inspect, or when the client certificate has to be examined.

Declare a Lambda authorizer with `scope_enforcement` and this repository deploys
its own function, described below, rather than asking for an ARN.

## What the bundled function checks

Standard library only — no layer, no build step, nothing to resolve at
invocation time. Checks run in this order, and every one of them denies:

1. **Configuration.** An issuer and at least one audience, or the authorizer
   refuses every request rather than deciding without them.
2. **A route key.** From `routeKey` or `requestContext.routeKey`. An event
   naming no route is denied, not defaulted.
3. **A token.** Read from `identitySource` first — that is what API Gateway
   extracted using the declared identity sources — falling back to the
   `Authorization` header. A `Bearer ` prefix is stripped.
4. **The signature**, RSASSA-PKCS1-v1_5 against the issuer's published keys.
5. **The issuer**, compared to the configured value after verification.
6. **`exp`**, which is *required* rather than checked when present, plus `nbf`
   when it is there. `clock_skew_seconds` (default `60`) tolerates disagreeing
   clocks.
7. **The audience**, from `aud`, or from `client_id` when `aud` is absent.
8. **The scopes**, from `scope` (space-delimited string) or `scp` (list), and
   **every** scope configured for the route must be present.

### Four decisions inside that list, and why

**The algorithm comes from the key, never from the token.** A verifier that
reads the token's own `alg` header can be handed `none`, or `HS256` keyed on the
RSA public key — which is public, so anyone can mint a token that verifies. When
a published key names no `alg`, RS256 is assumed and a token claiming anything
else is refused rather than allowed to revise the assumption.

**The key is selected by `kid`, with one refresh on an unknown id.** `kid` is
chosen by whoever made the token. Falling back to "any key that works" accepts a
token naming a key that was never published. The single refresh is what makes
issuer key rotation survivable without making an unknown `kid` a way to force
fetches.

**`exp` is required.** A token with no expiry never expires. A verifier that
only checks the claim when it is present treats the most dangerous token it can
be handed as the one with nothing to object to.

**`client_id` is read when `aud` is absent.** An OIDC id token carries `aud`; an
access token frequently does not — a Cognito access token names the app client
in `client_id` and has no `aud` at all. API Gateway's own JWT authorizer accepts
either, so a check insisting on `aud` would refuse every access token the same
issuer mints.

### A route with no scope entry is denied

```hcl
scope_enforcement = {
  issuer   = "https://issuer.example.invalid/tenant"
  audience = ["partner-api"]

  required_scopes = {
    "GET /orders"         = ["orders:read"]
    "POST /orders"        = ["orders:read", "orders:write"]
    "DELETE /orders/{id}" = ["orders:write", "orders:admin"]
  }
}
```

`unlisted_route_action` defaults to `deny`. A route added without deciding its
scopes fails closed: the mistake surfaces as a route that does not work, rather
than as a route that works for everyone. A `$default` entry provides a fallback
when one is wanted deliberately, and `allow` is available for a migration
window.

Now `DELETE /orders/{id}` means what the JWT example above only looked like it
meant. `scope_enforced_routes` reports which routes are decided this way, so the
two readings are never mistaken for one another.

### What reaches the integration

On an allow, the function returns context values — strings, because that is what
API Gateway delivers regardless:

| Key | Contents |
|---|---|
| `sub` | The token subject |
| `scope` | Every scope the token granted, space-delimited |
| `requiredScope` | The scopes this route required and the token satisfied |
| `issuer` | The configured issuer the token was verified against |

On a deny, the caller is told only that it was denied. The reason is written to
the function's log group — `scope_enforcement_log_groups` names it. An
authorizer that tells a caller *why* it refused is a way to probe scope
configuration one request at a time.

**Every failure denies, including an unreachable key set and an unexpected
exception.** An authorizer that failed open under load would be an availability
improvement that removes authorization exactly when the system is least healthy.

## Caching, and what it does to expiry

`result_ttl_in_seconds` defaults to `0` in this repository. That costs one
invocation per request, and buys the property that a token's own expiry is what
ends access.

With caching on, the answer is stored against the identity sources. A request
made one second before a token expires is answered from that cache for the rest
of the window — and so is every later request carrying the same token. A
five-minute TTL means a revoked or expired token keeps working for up to five
minutes.

Two further traps, both refused at plan time:

**Per-route decisions need `$context.routeKey` in the identity sources.** The
identity sources *are* the cache key. An authorizer that decides differently per
route, cached on the `Authorization` header alone, replays the decision made for
one route for every other route the same token reaches — and the scopes on those
routes stop being consulted. It passes any test that exercises a single route.

**Caching with no identity sources has nothing to key on.** Also refused.

`authorizers_with_cached_results` reports which decisions outlive the token that
produced them, and for how long.

## Provider defaults that are not stable

`result_ttl_in_seconds` is always sent explicitly. Left unset, the provider
supplies `300` itself — and *which* configurations it does that for changed
inside the version range this repository pins. The same file would yield a
cached authorizer on one resolved provider and an uncached one on another, with
no diff to explain the difference.

Two more that the provider accepts and API Gateway refuses:

- **A JWT authorizer with no audience.** The audience is the only thing tying a
  token to this API rather than to anything else the issuer signs.
- **An issuer pasted as its discovery or JWKS URL.** API Gateway appends the
  discovery path itself, so the URL resolves to nothing and every request is
  refused with a message about the token.

And one shape with no valid form: `enable_simple_responses` with payload format
`1.0`. A 1.0 authorizer answers with an IAM policy and has no simple response.

## The invoke grant

An authorizer's `execute-api` ARN carries **no stage, no method and no path**:

```
arn:aws:execute-api:<region>:<account>:<api-id>/authorizers/<authorizer-id>
```

A route's does. Deriving the authorizer's grant the way a route's is derived
produces a grant that can never match — and a grant that never matches fails
exactly like no grant at all: an internal server error, with nothing in the
access log naming permission as the cause. `authorizer_source_arns` reports what
each grant was actually scoped to, and
`authorizer_invocations_not_granted` reports what this configuration did not
grant at all (`manage_lambda_permissions = false` is the case where that is
intentional).

## Naming

One name cannot be used by both a JWT and a Lambda authorizer. The merged lookup
would silently keep one, and that one would decide the requests the other was
written for. Refused at plan time.

Routes reference an authorizer by **key**, not by identifier, because an
identifier only exists after an apply. A key that was never declared is refused
at plan time with the route and the key named — without that guard, the route
deploys with no authorization at all.

## Metered access is a different question

Authorization decides whether a caller may do something. **API keys decide
nothing.** A key identifies a caller for metering and throttling; it is sent in
a header, it is visible to anyone holding it, and it is not a credential. Access
control is the authorizer's job.

Two counting rules decide whether a limit is the limit anyone meant:

**A usage plan limit is per API key.** One plan rated at 50 requests a second
with twenty keys attached permits a thousand requests a second at the stage, and
a twenty-first client raises it again with nothing reconfigured. Only
`rest_api_stage_throttle` bounds the API as a whole.
`plans_above_the_stage_throttle` and
`total_plan_rate_if_every_key_is_at_its_limit` report the comparison. Both
throttles and quotas are best-effort targets rather than guaranteed ceilings, by
AWS's own description.

**A method that does not demand a key is not metered.** Keys, a plan and
attached clients can all exist while every request is served, counted against
nothing, and missing from every usage report.
`methods_not_requiring_an_api_key` names those methods.

API keys and usage plans exist only on a REST API, which is why
`enable_rest_api` is part of this question at all.

## Client certificates are authentication, not authorization

Mutual TLS proves the client holds a certificate the truststore trusts. It does
not decide what that client may do, and it does not check four things people
reasonably assume it checks — each with an output that says so:

| Not done | Output |
|---|---|
| Revocation checking | `mutual_tls_does_not_check_revocation` |
| Expiry warnings for certificates inside the truststore | `mutual_tls_truststore_expiry_not_notified` |
| Distinguishing untrusted from expired from unsupported-algorithm in its `403` | — the response is the same either way |
| Requiring a certificate on the generated `execute-api` endpoint | `mutual_tls_is_bypassable` |

The last one is the one that matters most: enabling mutual TLS on a custom
domain does not change the API's generated endpoint, so anything still holding
that URL keeps working with no certificate while the domain, the truststore and
the certificate all check out. The root refuses that pair unless
`allow_default_endpoint_with_mutual_tls` is set for a migration window, and
reports it for as long as it lasts.

**Revocation checking is a Lambda authorizer's job** — it receives the
certificate the client presented. That is why `modules/openapi-api` writes the
certificate's subject, issuer, serial and expiry into the access log, and
deliberately never writes the certificate itself.

## Checklist for a protected route

1. Are the scopes on this route alternatives or a requirement? Alternatives →
   JWT authorizer. Requirement → Lambda authorizer with `scope_enforcement`.
2. If caching is on, is `$context.routeKey` in the identity sources? If the
   authorizer decides per route, it must be.
3. Does `scope_enforced_routes` list this route? If it should be all-of and it
   is not listed, the list is being enforced as alternatives.
4. Does `authorizers_with_cached_results` list its authorizer? If so, expiry is
   delayed by the TTL.
5. Does `authorizer_invocations_not_granted` mention it? If so, requests will
   return `500` with nothing in the access log naming permission.
6. If browsers call it, is there an `OPTIONS /{proxy+}` route? Preflight carries
   no token and an authorizer will refuse it.
7. Is metering expected? Check `methods_not_requiring_an_api_key` and
   `plans_above_the_stage_throttle`.
