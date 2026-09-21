output "authorizer_ids" {
  description = "Every authorizer this module created, keyed by its name. This is the map a route's authorizer_id is looked up in."
  value       = merge(local.jwt_authorizer_id_map, local.lambda_authorizer_id_map)
}

output "jwt_authorizer_ids" {
  description = "Identifiers of the JWT authorizers, keyed by name."
  value       = local.jwt_authorizer_id_map
}

output "lambda_authorizer_ids" {
  description = "Identifiers of the Lambda authorizers, keyed by name."
  value       = local.lambda_authorizer_id_map
}

output "jwt_issuers" {
  description = "Issuer URL each JWT authorizer resolved to, keyed by name. A Cognito entry shows the URL derived from the pool id, which is the value a token's iss claim has to equal exactly."
  value       = local.jwt_issuers
}

output "authorizers_with_cached_results" {
  description = <<-EOT
    Lambda authorizers whose decisions are cached, and for how long.

    A cached decision outlives the token that produced it: a request made with a
    token that expires a second later is answered from cache for the rest of the
    window, and so is the next request carrying the same token. Anything not
    listed here re-decides every request.
  EOT
  value       = local.cached_authorizers
}

output "scope_enforced_routes" {
  description = <<-EOT
    Routes whose scopes are required in full, keyed by <authorizer>/<route key>.

    A route decided by a JWT authorizer with authorization_scopes on it is not
    in this list, and is not enforced this way: API Gateway grants such a route
    to a token holding ANY ONE of its scopes.
  EOT
  value       = local.scope_enforced_routes
}

output "authorizer_invocations_not_granted" {
  description = "Lambda authorizers whose functions this module did not grant API Gateway permission to invoke. Every route they decide answers with an internal server error until the grant is made elsewhere, which is indistinguishable from an authorizer that is failing."
  value       = var.manage_lambda_permissions ? [] : sort(keys(var.lambda_authorizers))
}

output "authorizer_source_arns" {
  description = "Source ARN each invoke grant is scoped to, keyed by authorizer name. An authorizer's execute-api ARN carries no stage, method or path, unlike a route's; this is the value to compare against when a grant is not matching."
  value       = local.authorizer_source_arns
}

output "scope_enforcement_function_names" {
  description = "Names of the authorizer functions this module built, keyed by authorizer name. Empty when every Lambda authorizer points at a function somebody else owns."
  value       = { for key, fn in aws_lambda_function.scope_enforcer : key => fn.function_name }
}

output "scope_enforcement_log_groups" {
  description = "Log group holding each bundled authorizer's decisions, keyed by authorizer name. A denial is recorded there with its reason; the caller is told only that it was denied."
  value       = { for key, group in aws_cloudwatch_log_group.scope_enforcer : key => group.name }
}
