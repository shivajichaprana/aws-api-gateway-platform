output "rest_api_id" {
  description = "Identifier of the REST API."
  value       = aws_api_gateway_rest_api.this.id
}

output "rest_api_arn" {
  description = "ARN of the REST API."
  value       = aws_api_gateway_rest_api.this.arn
}

output "execution_arn" {
  description = "Execution ARN of the API. This is the prefix an invocation grant is built from, and a Lambda integration needs one before it can be called."
  value       = aws_api_gateway_rest_api.this.execution_arn
}

output "root_resource_id" {
  description = "Identifier of the API's root resource."
  value       = aws_api_gateway_rest_api.this.root_resource_id
}

output "stage_name" {
  description = "Name of the deployed stage."
  value       = aws_api_gateway_stage.this.stage_name
}

output "stage_arn" {
  description = "ARN of the stage. This is what a web ACL association takes, and its shape is the reason an HTTP API cannot have one: there is no equivalent resource for a stage to associate."
  value       = aws_api_gateway_stage.this.arn
}

output "invoke_url" {
  description = "Base URL clients call. A REST API stage name is part of the path, unlike an HTTP API's $default stage."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "deployment_id" {
  description = "Deployment the stage is serving. A change to a method or an integration reaches clients only when this changes."
  value       = aws_api_gateway_deployment.this.id
}

output "access_log_group_name" {
  description = "Log group receiving stage access logs."
  value       = aws_cloudwatch_log_group.access.name
}

output "access_log_format" {
  description = "Access log format in force. Unlike an HTTP API a REST API can also write execution logs, but those need an account-wide role this module does not manage, so in a default deployment this is still the whole record of a request."
  value       = local.access_log_format
}

output "method_setting_paths" {
  description = "How each method is named in a stage throttle setting, by method key. A stage setting takes the resource path without its leading slash."
  value       = local.method_setting_paths
}

output "usage_plan_throttle_paths" {
  description = "How each method is named in a usage plan throttle, by method key. A usage plan takes the same path WITH its leading slash -- the two fields mean the same method and are spelled differently, which is why neither is accepted as text."
  value       = local.usage_plan_throttle_paths
}

output "api_key_ids" {
  description = "Identifiers of the API keys created, by name. The values are deliberately not output; they are already in state, and putting them in an output publishes them to anything that reads one."
  value       = { for key, api_key in aws_api_gateway_api_key.this : key => api_key.id }
}

output "usage_plan_ids" {
  description = "Identifiers of the usage plans created, by name."
  value       = { for key, plan in aws_api_gateway_usage_plan.this : key => plan.id }
}

output "methods_requiring_an_api_key" {
  description = "Methods that will refuse a request arriving without a key, by method key."
  value       = { for key, required in local.api_key_required : key => required }
}

# ---------------------------------------------------------------------------
# What this module did not do
# ---------------------------------------------------------------------------

output "methods_not_requiring_an_api_key" {
  description = "Methods served without a key. While usage plans exist, each of these is a request that is answered, is counted against no plan, and appears in no usage report -- the API meters the callers it can identify and serves the ones it cannot."
  value       = local.has_usage_plans ? local.methods_not_requiring_an_api_key : []
}

output "methods_reachable_without_authorization" {
  description = "Methods with no authorizer and no key requirement. Anyone who can reach the endpoint can call these."
  value       = local.methods_reachable_without_authorization
}

output "api_keys_not_attached_to_any_plan" {
  description = "Keys attached to no usage plan. A request carrying one of these is refused with 403, because API Gateway checks that a key maps to a plan covering the stage rather than that the key exists."
  value       = local.keys_not_attached_to_any_plan
}

output "stage_aggregate_throttle" {
  description = "The only ceiling on the API as a whole, or null when the stage is left at the account limit. Every usage plan limit is per key and cannot bound the total."
  value       = var.stage_throttle
}

output "plan_rate_if_every_key_is_at_its_limit" {
  description = "Requests a second the stage would receive if every key on every plan ran at its plan's rate, by plan. This is what the plans permit in aggregate, and it rises by one plan's rate each time a client is added."
  value       = local.plan_aggregate_rate
}

output "total_plan_rate_if_every_key_is_at_its_limit" {
  description = "The same figure summed across plans, for comparison with stage_aggregate_throttle."
  value       = local.total_plan_rate_if_every_key_is_at_its_limit
}

output "plans_above_the_stage_throttle" {
  description = "Plans whose keys together may ask for more than the stage will serve. Those requests are refused at the stage with 429, which is attributed to no client and looks to every one of them like the API being slow."
  value       = local.plans_above_the_stage_throttle
}

output "quota_and_throttle_are_best_effort" {
  description = "Whether anything here depends on a usage plan limit. AWS describes both throttles and quotas as targets applied on a best-effort basis rather than guaranteed ceilings, so a plan shapes traffic and does not enforce a contract."
  value       = local.has_usage_plans
}

output "api_key_values_are_held_in_state" {
  description = "Whether this module created API keys. Their generated values are read back by the provider, so the state file is as sensitive as the keys in it and there is no configuration that changes that."
  value       = length(var.api_keys) > 0
}

output "execution_logging_not_configured" {
  description = "Always true. A REST API can write execution logs, which record what happened inside the gateway rather than what was returned, but they need a CloudWatch role set in account-wide API Gateway settings. That setting is a singleton per account and region, so two stacks that both manage it overwrite each other, and this module deliberately leaves it alone."
  value       = true
}

output "web_acl_associated" {
  description = "Whether a web ACL is attached to the stage."
  value       = var.web_acl_arn != null
}
