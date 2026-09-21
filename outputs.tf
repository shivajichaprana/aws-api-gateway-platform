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
