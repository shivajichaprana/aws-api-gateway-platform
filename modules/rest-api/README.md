# modules/rest-api

A REST API with metered access: methods, a deployed stage, API keys, usage
plans, throttling at both levels, and a web ACL association.

## Why this is a REST API

Three things have no HTTP API form at all:

| Capability | HTTP API | REST API |
|---|---|---|
| API keys | not supported | `x-api-key`, or an authorizer's usage identifier |
| Usage plans and quotas | not supported | per key, per stage, per method |
| AWS WAF web ACL | not supported | associated with the stage |

None of them is a setting that can be turned on later, so an API that has to
tell its callers apart, cap them, or sit behind a firewall is a REST API from
the beginning or it is rebuilt as one. That is the whole reason this module
exists beside `modules/http-api`.

## The failure this module exists to remove

`api_key_required` defaults to **false** on a method, in the service and in the
provider. So this is a complete, working, entirely unmetered API:

- API keys created and handed to clients
- a usage plan with a rate limit and a monthly quota
- every key attached to the plan
- the plan attached to the stage
- every method served without a key, counted against nothing, and absent from
  every usage report

Nothing in the console contradicts any of it. The plan page shows the plan, the
keys page shows the keys, the usage page shows zero.

So `api_key_required` is not defaulted here. Left unset on a method it follows
`default_api_key_required`, which is itself derived: required when the module
creates at least one usage plan, and not otherwise. A method that genuinely
should be open -- a health check -- says so, and then appears in
`methods_not_requiring_an_api_key` for as long as plans exist.

## An API key is not a credential

API Gateway checks that the key exists and maps to a plan covering this stage.
It checks nothing about who holds it. Use a key for *how much*, and an
authorizer or IAM for *who* -- `methods_reachable_without_authorization`
reports the methods where neither question is being asked.

Two consequences worth knowing before the first apply:

- The generated value is read back by the provider, so **the state for this
  module holds every key it creates**. Supplying your own value is not offered,
  because that would put the same credential in the configuration too. Nothing
  changes this; treat the state as key material.
- `api_key_source = "AUTHORIZER"` makes API Gateway read the key from whatever
  the request authorizer returned as its usage identifier and ignore the header
  entirely, so a client sending a perfectly good `x-api-key` is metered against
  nothing.

## Per-key limits do not bound anything

A usage plan's throttle and quota apply **per API key**. Ten keys on a plan
rated at 100 requests a second are up to 1000 requests a second arriving at the
stage, and adding an eleventh client raises the ceiling again with nothing
reconfigured and nothing reported.

`stage_throttle` is the only aggregate ceiling the API has. The module reports
both sides of the comparison:

- `plan_rate_if_every_key_is_at_its_limit`, per plan
- `total_plan_rate_if_every_key_is_at_its_limit`, summed
- `plans_above_the_stage_throttle`, where the plan promises more than the stage
  will serve -- those requests are refused at the stage with `429`, attributed
  to no client, and look to every one of them like the API being slow

API Gateway applies the levels in a fixed order: per-client and per-client
per-method limits from the usage plan, then per-method limits set on the stage,
then the account limit for the region, then the AWS limit. Both throttles and
quotas are described by AWS as **best-effort targets rather than guaranteed
ceilings**, so a plan shapes traffic; it does not enforce a contract.

## Two fields that name a method, spelled differently

A stage method setting identifies a method by its resource path **without** the
leading slash, and a usage plan throttle by the same path **with** it:

| Setting | Form | Example |
|---|---|---|
| `aws_api_gateway_method_settings.method_path` | `resource/path/VERB` | `orders/{id}/GET` |
| usage plan `api_stages.throttle.path` | `/resource/path/VERB` | `/orders/{id}/GET` |

Neither is accepted as text here. Both are derived from the method's own
declaration, and a throttle names the method by its key in `methods`, because
API Gateway accepts a throttle setting for a path that matches nothing in the
API: it is stored, it reads as though it applies to something, and it applies
to nothing. `method_setting_paths` and `usage_plan_throttle_paths` report what
was derived.

A throttle naming a method on the root path is refused. A root method has no
resource of its own and this module will not guess the string that identifies
it -- a guessed string is exactly the silent setting above.

## A deployment is a snapshot

A REST API stage serves the deployment it was given. Change a method or an
integration and nothing a client can see changes until a new deployment exists,
and nothing reports it: the console shows the new configuration while the API
serves the old one, and a method added that way answers
`{"message":"Not Found"}`.

The module hashes everything a deployment captures into the deployment's
`triggers`, so any change to it produces a new one, and sets
`create_before_destroy` so the stage is never left pointing at a deployment
that is being removed. `deployment_id` reports which snapshot is live.

## The resource tree is built one depth at a time

Each API Gateway resource names its parent, and Terraform refuses a resource
block whose configuration references another instance of itself -- a cycle at
the block level, even when the instances form a tree. So the module has one
block per depth and supports paths up to **5** segments. That limit is this
module's, not API Gateway's; deepening it means adding a block.

A path variable is part of the resource, so `/orders/{id}` and
`/orders/{orderId}` are two different resources under one parent and API
Gateway refuses the pair. Terraform would create the first and fail on the
second, so the conflict is refused at plan time instead.

## Logging

The stage writes access logs in a format carrying the fields that separate
causes rather than restate the response: `integration.status` against `status`
shows where API Gateway changed the answer, `integration.error` is the only
place the reason for a `5xx` is written down, `identity.apiKeyId` makes a
throttled request attributable to a caller rather than to the stage, and
`wafResponseCode` distinguishes a request the web ACL refused from one the API
did.

Unlike an HTTP API, a REST API can also write **execution** logs, which record
what happened inside the gateway. Those need a CloudWatch role set in
account-wide API Gateway settings, and that setting is a singleton per account
and region: two stacks that both manage it overwrite each other. This module
leaves it alone and says so in `execution_logging_not_configured`.

## Protection

`web_acl_arn` takes a **regional** web ACL in this API's own region. Both facts
are read out of the ARN at plan time, because the mistake they prevent is
invisible afterwards -- a CloudFront-scoped ACL looks identical in the console,
and an edge-optimized API does not change the answer, since the distribution in
front of it belongs to API Gateway rather than to this account.

## Usage

```hcl
module "rest_api" {
  source = "./modules/rest-api"

  name       = "orders"
  stage_name = "live"

  methods = {
    list-orders = {
      path        = "/orders"
      http_method = "GET"
      integration = {
        type                 = "AWS_PROXY"
        uri                  = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:orders/invocations"
        timeout_milliseconds = 10000
      }
    }
    health = {
      path             = "/health"
      http_method      = "GET"
      api_key_required = false
      integration = {
        type = "MOCK"
      }
    }
  }

  stage_throttle = {
    rate_limit  = 500
    burst_limit = 1000
  }

  api_keys = {
    partner-a = {}
    partner-b = {}
  }

  usage_plans = {
    standard = {
      api_keys = ["partner-a", "partner-b"]
      throttle = {
        rate_limit  = 50
        burst_limit = 100
      }
      quota = {
        limit  = 1000000
        period = "MONTH"
      }
      method_throttles = {
        list-orders = {
          rate_limit  = 20
          burst_limit = 40
        }
      }
    }
  }

  web_acl_arn = module.waf.web_acl_arn

  tags = { Component = "api-platform" }
}
```

## Inputs

| Name | Type | Default | Purpose |
|---|---|---|---|
| `name` | `string` | required | Name of the REST API |
| `description` | `string` | `"REST API with metered access"` | Description on the API |
| `endpoint_type` | `string` | `"REGIONAL"` | Where the API is served from |
| `stage_name` | `string` | `"live"` | Stage serving the API |
| `methods` | `map(object)` | `{}` | Methods, their integrations and their authorization |
| `default_api_key_required` | `bool` | `null` | Fallback for a method that does not say; null derives it from whether plans exist |
| `api_key_source` | `string` | `"HEADER"` | Where API Gateway reads the key from |
| `stage_throttle` | `object` | `null` | Aggregate ceiling for the whole stage |
| `method_throttles` | `map(object)` | `{}` | Aggregate per-method ceilings, keyed by method key |
| `api_keys` | `map(object)` | `{}` | Keys to create |
| `usage_plans` | `map(object)` | `{}` | Plans, their keys, throttles and quotas |
| `access_log_retention_days` | `number` | `90` | Retention for the access log group |
| `access_log_kms_key_arn` | `string` | `null` | Customer-managed key for the access log group |
| `metrics_enabled` | `bool` | `true` | Publish per-method CloudWatch metrics |
| `xray_tracing_enabled` | `bool` | `false` | Sample requests into X-Ray |
| `web_acl_arn` | `string` | `null` | Regional web ACL to associate with the stage |
| `tags` | `map(string)` | `{}` | Tags applied to what this module creates |

## Outputs

| Name | Purpose |
|---|---|
| `rest_api_id` | Identifier of the API |
| `rest_api_arn` | ARN of the API |
| `execution_arn` | Prefix an invocation grant is built from |
| `root_resource_id` | Identifier of the root resource |
| `stage_name` | Name of the deployed stage |
| `stage_arn` | ARN a web ACL association takes |
| `invoke_url` | Base URL clients call |
| `deployment_id` | Snapshot the stage is serving |
| `access_log_group_name` | Log group receiving access logs |
| `access_log_format` | Access log format in force |
| `method_setting_paths` | How each method is named in a stage throttle |
| `usage_plan_throttle_paths` | How each method is named in a plan throttle |
| `api_key_ids` | Identifiers of the keys created |
| `usage_plan_ids` | Identifiers of the plans created |
| `methods_requiring_an_api_key` | Whether each method demands a key |
| `methods_not_requiring_an_api_key` | Methods served unmetered while plans exist |
| `methods_reachable_without_authorization` | Methods with neither an authorizer nor a key |
| `api_keys_not_attached_to_any_plan` | Keys that will be refused with `403` |
| `stage_aggregate_throttle` | The only ceiling on the API as a whole |
| `plan_rate_if_every_key_is_at_its_limit` | Per-plan aggregate the keys permit |
| `total_plan_rate_if_every_key_is_at_its_limit` | The same summed across plans |
| `plans_above_the_stage_throttle` | Plans promising more than the stage serves |
| `quota_and_throttle_are_best_effort` | Whether anything depends on a plan limit |
| `api_key_values_are_held_in_state` | Whether the state holds key material |
| `execution_logging_not_configured` | Execution logs need an account-wide role this module leaves alone |
| `web_acl_associated` | Whether a web ACL is attached to the stage |
