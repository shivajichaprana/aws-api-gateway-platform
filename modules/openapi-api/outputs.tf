output "rest_api_id" {
  description = "Identifier of the REST API."
  value       = aws_api_gateway_rest_api.this.id
}

output "rest_api_arn" {
  description = "ARN of the REST API."
  value       = aws_api_gateway_rest_api.this.arn
}

output "execution_arn" {
  description = "Execution ARN of the API. This is what an invocation grant or a resource policy written elsewhere is built from."
  value       = aws_api_gateway_rest_api.this.execution_arn
}

output "root_resource_id" {
  description = "Identifier of the root resource API Gateway created from the document."
  value       = aws_api_gateway_rest_api.this.root_resource_id
}

output "stage_name" {
  description = "Name of the deployed stage."
  value       = aws_api_gateway_stage.this.stage_name
}

output "stage_arn" {
  description = "ARN of the stage. A web ACL association and a base path mapping both need it."
  value       = aws_api_gateway_stage.this.arn
}

output "invoke_url" {
  description = "Generated execute-api URL for the stage. It keeps being returned once the default endpoint is disabled, and stops answering -- so a caller still holding it gets a connection failure rather than a redirect."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "deployment_id" {
  description = "Identifier of the deployment the stage is serving."
  value       = aws_api_gateway_deployment.this.id
}

output "document_sha1" {
  description = "Hash of the rendered document that produced this deployment. Two APIs reporting the same hash are serving the same routing."
  value       = sha1(var.openapi_body)
}

output "document_title" {
  description = "Title the document declares. Null when it declares none."
  value       = local.document_title
}

output "operations" {
  description = "Every operation the document declares, as method and path. This is the API's route table, read back out of the document that built it."
  value       = sort(keys(local.operations))
}

output "operation_count" {
  description = "Number of operations the document declares."
  value       = length(local.operations)
}

output "access_log_group_name" {
  description = "Log group receiving access logs."
  value       = local.access_log_group_name
}

output "access_log_format" {
  description = "Access log format in use. A REST API does have execution logging as well, which this module does not configure, but the fields here are what separate one cause of a 5xx from another."
  value       = local.access_log_format
}

# ---------------------------------------------------------------------------
# What was not done
# ---------------------------------------------------------------------------

output "operations_declaring_no_authorization" {
  description = <<-EOT
    Operations reachable without credentials: those overriding the document's
    requirement with an empty list, and every operation when the document
    declares no requirement at all. An open operation is legitimate -- a
    liveness probe should not need a credential that rotates -- and an open
    operation nobody meant to open looks exactly the same in the document.
  EOT
  value       = local.operations_declaring_no_authorization
}

output "document_requires_authorization" {
  description = "Whether the document carries a top-level security requirement, which is what an operation that says nothing about authorization inherits."
  value       = local.document_requires_authorization
}

output "functions_the_document_integrates_with" {
  description = "Function names read out of the integration URIs in the document, rather than out of a second list that has to be kept in step with it."
  value       = local.document_function_names
}

output "functions_without_an_invocation_grant" {
  description = <<-EOT
    Functions the document integrates with that this module was not asked to
    grant. Each one answers 500 on the first call, and the response says nothing
    about permissions -- it is the same answer a handler that threw gives.

    Non-empty is not automatically wrong: a function in another account, or one
    whose policy is managed by the stack that owns it, is granted elsewhere. It
    is wrong when nobody can name where.
  EOT
  value       = local.functions_without_an_invocation_grant
}

output "invocation_source_arns" {
  description = "Source ARN each granted function was scoped to. A path variable is wildcarded, because a grant naming a literal {id} matches only a request for that string."
  value       = { for k, v in aws_lambda_permission.integrations : k => v.source_arn }
}

output "operations_removed_from_the_document_are_left_in_place" {
  description = <<-EOT
    True in merge mode. The document then stops being a description of the API:
    an operation deleted from it keeps serving, and nothing reports the
    difference. False in overwrite mode, which is the default -- at the cost
    that literal properties of the API not mentioned in the document are
    deleted by the import and only some of them are reconciled afterwards.
  EOT
  value       = var.put_rest_api_mode == "merge"
}

output "import_warnings_ignored" {
  description = <<-EOT
    True when warnings are not fatal, which is the service's own default and not
    this module's. A document with an unrecognised extension key or an
    integration API Gateway cannot parse is then imported without those parts,
    and the apply succeeds.
  EOT
  value       = !var.fail_on_warnings
}

output "default_endpoint_enabled" {
  description = <<-EOT
    True while the generated execute-api endpoint answers. It requires no client
    certificate, so an API fronted by a custom domain with mutual TLS still has
    a way in that asks for nothing -- and every check of the domain passes while
    that is true.
  EOT
  value       = !var.disable_default_endpoint
}

output "unreferenced_request_validators" {
  description = "Validators the document declares and no operation points at. Each one validates nothing, while the parameters and schemas it would have enforced are still in the document."
  value       = local.unreferenced_validators
}

output "document_title_differs_from_the_api_name" {
  description = "True when the document's title is not the API's name. Not an error -- the import takes the title and the provider patches the configured name back over it -- but the two are then read differently depending on where you look."
  value       = local.document_title != null && local.document_title != var.name
}

output "execution_logging_not_configured" {
  description = "This module configures access logging only. Execution logging exists for a REST API and is far more detailed, which is also why it is not on by default: it records request and response bodies."
  value       = true
}

output "client_certificate_fields_logged" {
  description = "Whether the access log records the subject, issuer, serial and expiry of the presented client certificate. The certificate itself is never logged."
  value       = var.log_client_certificate_fields
}
