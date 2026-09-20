output "api_id" {
  description = "Identifier of the HTTP API."
  value       = aws_apigatewayv2_api.this.id
}

output "api_arn" {
  description = "ARN of the HTTP API."
  value       = aws_apigatewayv2_api.this.arn
}

output "api_execution_arn" {
  description = "Execution ARN of the API. This is the prefix an invocation grant is built from, and it is what an authorizer or a resource policy written elsewhere needs."
  value       = aws_apigatewayv2_api.this.execution_arn
}

output "api_endpoint" {
  description = "Generated execute-api endpoint for the API. Null once the default endpoint is disabled, because it no longer answers."
  value       = var.disable_default_endpoint ? null : aws_apigatewayv2_api.this.api_endpoint
}

output "stage_name" {
  description = "Name of the deployed stage."
  value       = aws_apigatewayv2_stage.this.name
}

output "invoke_url" {
  description = <<-EOT
    Base URL clients call. The $default stage is served at the root of the API
    endpoint and any other stage underneath its own name, so this is not simply
    the endpoint with the stage appended.
  EOT
  value       = var.disable_default_endpoint ? null : aws_apigatewayv2_stage.this.invoke_url
}

output "route_keys" {
  description = "Route keys served by the API, by route name."
  value       = { for k, v in var.routes : k => v.route_key }
}

output "integration_ids" {
  description = "Integration identifiers, by integration name."
  value       = { for k, v in aws_apigatewayv2_integration.this : k => v.id }
}

output "access_log_group_name" {
  description = "Log group receiving access logs."
  value       = local.log_group_name
}

output "access_log_format" {
  description = "Access log format in force. An HTTP API records nothing anywhere else, so this is the complete list of what will be known about a request after it has been answered."
  value       = local.access_log_format
}

output "effective_route_settings" {
  description = "Throttling and metrics actually in force per route key, after each route's own settings have been resolved against the stage defaults."
  value       = local.route_settings
}

# ---------------------------------------------------------------------------
# What this module did not do
# ---------------------------------------------------------------------------

output "lambda_permissions_not_managed" {
  description = "Routes reaching a Lambda function that this module did not grant API Gateway permission to invoke, and why. Each of these answers with an internal server error until the grant is made elsewhere, and the response body is identical to every other integration failure."
  value       = local.ungrantable_lambda_routes
}

output "routes_matching_unlisted_paths" {
  description = "Routes declared with the $default key. Each one catches every request no other route matched, so a misspelled path reaches a backend instead of returning 404, and adding a route later silently narrows what this one receives."
  value       = local.default_route_keys
}

output "default_endpoint_enabled" {
  description = "Whether the generated execute-api endpoint still answers. While it does, a client can reach the API without going through any custom domain, and therefore without whatever is attached to that domain rather than to the stage."
  value       = !var.disable_default_endpoint
}

output "integration_cors_headers_discarded" {
  description = "True when CORS is configured on the API. API Gateway then answers preflight requests itself and discards any CORS headers the integration returns, so a backend setting its own is overridden without either side reporting it."
  value       = var.cors_configuration != null
}
