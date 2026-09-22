# modules/waf

A regional AWS WAF web ACL for an API Gateway stage, shipped observing rather
than blocking.

## Why the scope is not an input

A web ACL is created either `REGIONAL` or `CLOUDFRONT`. The two are separate
objects, a CloudFront one has to live in `us-east-1`, and an API Gateway stage
accepts only a regional one in the API's own region.

That holds for an **edge-optimized** API as well, which is the part that
surprises people: an edge-optimized API is served through a CloudFront
distribution, but the distribution is created and owned by API Gateway, so
there is nothing in this account to attach a CloudFront ACL to. The association
is with the stage either way.

Offering `scope` as an input would only make the wrong answer reachable, so the
module does not have one. The consuming module reads the scope back out of the
ARN and refuses a global one.

## Why every rule group starts in count mode

`enforced_rule_groups` is empty by default, so every managed group is evaluated
with its override set to `count`. Each group still runs, still labels requests
and still publishes a metric; none of them can terminate a request.

A managed rule group dropped onto a live API in blocking mode rejects real
traffic the first time one of its rules is wrong about a request, and which
rules are wrong about which requests is a property of the workload, not of the
group. Counting first turns that from an incident into a metric. `make`-style
progress is a group at a time: read the counts, override the individual rules
that misfire with `rule_action_overrides`, then add the group to
`enforced_rule_groups`.

`rule_groups_not_enforcing` reports what is still counting, so "the API is
behind a WAF" and "the WAF can refuse a request" stay distinguishable.

## Capacity is charged before it is checked

A web ACL has a capacity budget in WCUs, and a rule group costs the ACL its own
immutable capacity setting. Exceed the budget and the ACL is refused **when it
is created** -- after every rule in it reads correctly.

The module checks the total at plan time, but only over groups whose capacity
was declared. The authoritative number belongs to the group's owner:

```bash
aws wafv2 describe-managed-rule-group \
  --scope REGIONAL --vendor-name AWS \
  --name AWSManagedRulesCommonRuleSet \
  --query Capacity
```

A group that declares none is left out of the sum and named in
`rule_groups_without_declared_capacity`, so `declared_capacity` is a lower bound
rather than a claim about the ACL. `web_acl_capacity` is the real figure once
AWS has calculated it.

`capacity_budget` defaults to 1500 because that is what the basic web ACL price
includes. Up to 5000 is allowed without a limit increase, and everything past
1500 is charged, so raising it is a billing decision taken on purpose.

## The rate limit is per five minutes

`rate_limit_per_five_minutes` is named after its unit because that unit is the
single most misread number in a web ACL. AWS WAF counts a rate-based rule over
an **evaluation window**, not per second. A limit of 2000 is roughly seven
requests a second.

The window is fixed at the service default of 300 seconds. Choosing a shorter
one needs `evaluation_window_sec`, which does not exist in every provider
version this repository's constraint allows, and a configuration that plans on
some of its permitted providers and not others is worse than one window.

The floor of 100 is the same intersection. AWS now accepts limits as low as 10,
and the provider accepts 10 from v5.44.0 onward, but at 5.0.0 it validates the
field at 100 and refuses anything smaller before a request is ever made.

## Ordering decides behaviour

Rules are evaluated from the lowest priority number upward and evaluation stops
at the first terminating action. So an address on `allowed_ip_addresses` is
allowed at priority 10 and never reaches the managed groups at 100 and above.

That is what an allow-list is for, so it is reported rather than refused:
`rules_shadowed_by_an_earlier_allow` names every rule an allow-listed caller
skips. A duplicate priority *is* refused, because AWS WAF requires them to be
unique and the failure otherwise arrives at creation time.

A rule whose statement is a managed rule group carries `override_action` and
never `action`; an ordinary rule is the reverse. Getting it the wrong way round
is rejected, so neither is an input -- both are derived from what the rule is.

## Logging, and the credentials in it

A web ACL writes nothing anywhere until logging is on, which means a rule that
fired and a rule that has never matched anything leave the same evidence.

The destination name is derived rather than validated: AWS WAF refuses a
logging destination whose name does not start with `aws-waf-logs-`, and refuses
it at the point the logging configuration is created, by which time the log
group already exists.

`redacted_headers` defaults to `authorization` and `x-api-key` because a log
record carries the headers of the request it describes. Without redaction a
bearer token and an API key are written into a log group in clear text and
every reader of that group holds them. Header names must be lower case; AWS WAF
returns them that way, and a mixed-case entry is a difference that never
settles.

`log_only_non_default_actions` drops records for requests the default action
handled. It is refused while any managed group is still counting, because a
counting group never terminates a request -- its findings are exactly the
records that filter discards, so the ACL would appear to be protecting the API
and write down nothing about what it found.

## Usage

```hcl
module "waf" {
  source = "./modules/waf"

  name = "orders-api"

  enforced_rule_groups        = ["known-bad-inputs"]
  rate_limit_per_five_minutes = 3000

  blocked_ip_addresses = ["203.0.113.0/24"]

  managed_rule_groups = {
    common = {
      name     = "AWSManagedRulesCommonRuleSet"
      priority = 100
      capacity = 700
      rule_action_overrides = {
        SizeRestrictions_BODY = "count"
      }
    }
    known-bad-inputs = {
      name     = "AWSManagedRulesKnownBadInputsRuleSet"
      priority = 110
      capacity = 200
    }
  }

  tags = { Component = "api-platform" }
}
```

The capacities above are illustrative. Read the real ones with
`describe-managed-rule-group` before relying on the budget check.

## Inputs

| Name | Type | Default | Purpose |
|---|---|---|---|
| `name` | `string` | required | Web ACL name; the log group is `aws-waf-logs-<name>` |
| `description` | `string` | `"Regional web ACL protecting an API Gateway stage"` | Description on the ACL |
| `default_action` | `string` | `"allow"` | What happens to a request no rule matched |
| `managed_rule_groups` | `map(object)` | four AWS groups | Groups to evaluate, with priority and optional capacity |
| `enforced_rule_groups` | `set(string)` | `[]` | Groups permitted to block; everything else counts |
| `capacity_budget` | `number` | `1500` | WCUs the ACL may declare |
| `allowed_ip_addresses` | `list(string)` | `[]` | Addresses admitted ahead of every other rule |
| `blocked_ip_addresses` | `list(string)` | `[]` | Addresses refused outright |
| `allow_list_priority` | `number` | `10` | Priority of the allow-list rule |
| `block_list_priority` | `number` | `20` | Priority of the block-list rule |
| `rate_limit_per_five_minutes` | `number` | `null` | Requests per address per five minutes; null disables the rule |
| `rate_limit_priority` | `number` | `30` | Priority of the rate-based rule |
| `rate_limit_action` | `string` | `"block"` | What happens to a source over the limit |
| `rate_limit_aggregate_key_type` | `string` | `"IP"` | What the rate is counted against |
| `rate_limit_forwarded_ip_header` | `string` | `"X-Forwarded-For"` | Header read when aggregating on a forwarded address |
| `enable_logging` | `bool` | `true` | Record the requests the ACL acts on |
| `log_retention_days` | `number` | `90` | Retention for the log group |
| `log_kms_key_arn` | `string` | `null` | Customer-managed key for the log group |
| `redacted_headers` | `list(string)` | `["authorization", "x-api-key"]` | Headers removed from each record |
| `log_only_non_default_actions` | `bool` | `false` | Drop records for requests the default action handled |
| `tags` | `map(string)` | `{}` | Tags applied to what this module creates |

## Outputs

| Name | Purpose |
|---|---|
| `web_acl_arn` | ARN an API Gateway stage association takes |
| `web_acl_id` | Identifier of the web ACL |
| `web_acl_name` | Name of the web ACL |
| `web_acl_capacity` | Capacity AWS WAF calculated, once the ACL exists |
| `rule_priorities` | Priority of every rule, by rule name |
| `log_group_name` | Log group receiving matched-request records |
| `redacted_headers` | Headers removed from each record |
| `rule_groups_not_enforcing` | Groups still counting rather than blocking |
| `rule_groups_without_declared_capacity` | Groups left out of the budget check |
| `declared_capacity` | Total checked at plan time |
| `capacity_budget` | Capacity the ACL was allowed to declare |
| `rules_shadowed_by_an_earlier_allow` | Rules an allow-listed address never reaches |
| `logging_enabled` | Whether the ACL records what it acts on |
| `rate_limit_window_seconds` | Window the rate rule counts over |
