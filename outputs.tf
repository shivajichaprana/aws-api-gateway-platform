output "api_id" {
  description = "Identifier of the HTTP API."
  value       = module.http_api.api_id
}

output "api_execution_arn" {
  description = "Execution ARN of the API, which an authorizer or an invocation grant written elsewhere is built from."
  value       = module.http_api.api_execution_arn
}

output "api_endpoint" {
  description = "Generated execute-api endpoint, or null once the default endpoint is disabled."
  value       = module.http_api.api_endpoint
}

output "invoke_url" {
  description = "Base URL clients call."
  value       = module.http_api.invoke_url
}

output "stage_name" {
  description = "Name of the deployed stage."
  value       = module.http_api.stage_name
}

output "route_keys" {
  description = "Route keys served by the API, by route name."
  value       = module.http_api.route_keys
}

output "effective_route_settings" {
  description = "Throttling and metrics in force per route key."
  value       = module.http_api.effective_route_settings
}

output "access_log_group_name" {
  description = "Log group receiving access logs."
  value       = module.http_api.access_log_group_name
}

output "access_log_format" {
  description = "Access log format in force, which is the complete list of what is recorded about a request."
  value       = module.http_api.access_log_format
}

output "access_log_kms_key_arn" {
  description = "Key encrypting the access log group, or null when the group uses the CloudWatch Logs default."
  value       = local.key_arn
}

output "lambda_permissions_not_managed" {
  description = "Routes whose Lambda invocation grant was not written here, and why."
  value       = module.http_api.lambda_permissions_not_managed
}

output "routes_matching_unlisted_paths" {
  description = "Routes declared with the $default key, each of which receives every request no other route matched."
  value       = module.http_api.routes_matching_unlisted_paths
}

output "default_endpoint_enabled" {
  description = "Whether the generated execute-api endpoint still answers, bypassing any custom domain in front of the API."
  value       = module.http_api.default_endpoint_enabled
}

output "integration_cors_headers_discarded" {
  description = "True when CORS is configured, in which case API Gateway discards any CORS headers the integration returns."
  value       = module.http_api.integration_cors_headers_discarded
}

# ---------------------------------------------------------------------------
# Authorizers
# ---------------------------------------------------------------------------

output "authorizer_ids" {
  description = "Every authorizer, keyed by the name routes refer to."
  value       = module.authorizers.authorizer_ids
}

output "jwt_issuers" {
  description = "Issuer URL each JWT authorizer resolved to. A Cognito entry shows the URL derived from the pool id, which is what a token's iss claim has to equal exactly."
  value       = module.authorizers.jwt_issuers
}

output "authorizers_with_cached_results" {
  description = "Lambda authorizers whose decisions are cached, and for how long. A cached allow outlives the token that produced it for the rest of the window."
  value       = module.authorizers.authorizers_with_cached_results
}

output "scope_enforced_routes" {
  description = "Routes whose scopes are required in full, keyed by <authorizer>/<route key>. A JWT route carrying authorization_scopes is not here and is satisfied by any one of them."
  value       = module.authorizers.scope_enforced_routes
}

output "authorizer_invocations_not_granted" {
  description = "Lambda authorizers whose functions were not granted to API Gateway by this configuration."
  value       = module.authorizers.authorizer_invocations_not_granted
}

output "scope_enforcement_log_groups" {
  description = "Log group holding each bundled authorizer's decisions. A denial is recorded there with its reason; the caller is told only that it was denied."
  value       = module.authorizers.scope_enforcement_log_groups
}

# ---------------------------------------------------------------------------
# Metered access
# ---------------------------------------------------------------------------

output "rest_api_id" {
  description = "Identifier of the REST API, or null when it is not deployed."
  value       = one(module.rest_api[*].rest_api_id)
}

output "rest_api_invoke_url" {
  description = "Base URL of the REST API stage, or null when it is not deployed."
  value       = one(module.rest_api[*].invoke_url)
}

output "rest_api_stage_arn" {
  description = "ARN of the REST API stage. This is what a web ACL associates with."
  value       = one(module.rest_api[*].stage_arn)
}

output "api_key_ids" {
  description = "Identifiers of the API keys created. Values are not published here; they are already in state."
  value       = one(module.rest_api[*].api_key_ids)
}

output "usage_plan_ids" {
  description = "Identifiers of the usage plans created."
  value       = one(module.rest_api[*].usage_plan_ids)
}

output "methods_not_requiring_an_api_key" {
  description = "Methods served without a key while usage plans exist. Each is answered, metered against nothing, and absent from every usage report."
  value       = one(module.rest_api[*].methods_not_requiring_an_api_key)
}

output "plans_above_the_stage_throttle" {
  description = "Usage plans whose keys together may ask for more than the stage will serve."
  value       = one(module.rest_api[*].plans_above_the_stage_throttle)
}

output "total_plan_rate_if_every_key_is_at_its_limit" {
  description = "Requests a second the stage would receive if every key on every plan ran at its plan's rate. Compare it with the stage throttle."
  value       = one(module.rest_api[*].total_plan_rate_if_every_key_is_at_its_limit)
}

# ---------------------------------------------------------------------------
# Protection
# ---------------------------------------------------------------------------

output "web_acl_arn" {
  description = "ARN of the regional web ACL, or null when it is not deployed."
  value       = one(module.waf[*].web_acl_arn)
}

output "web_acl_capacity" {
  description = "Capacity the web ACL consumes, in WCUs, as calculated by AWS WAF."
  value       = one(module.waf[*].web_acl_capacity)
}

output "waf_rule_groups_not_enforcing" {
  description = "Managed rule groups evaluated in count mode. Until this is empty the ACL observes and does not refuse."
  value       = one(module.waf[*].rule_groups_not_enforcing)
}

output "waf_rule_groups_without_declared_capacity" {
  description = "Managed rule groups left out of the capacity check because no capacity was declared for them."
  value       = one(module.waf[*].rule_groups_without_declared_capacity)
}

output "waf_rules_shadowed_by_an_earlier_allow" {
  description = "Rules that an address on the allow-list never reaches, including the managed rule groups."
  value       = one(module.waf[*].rules_shadowed_by_an_earlier_allow)
}

output "waf_log_group_name" {
  description = "Log group receiving matched-request records for the web ACL."
  value       = one(module.waf[*].log_group_name)
}
