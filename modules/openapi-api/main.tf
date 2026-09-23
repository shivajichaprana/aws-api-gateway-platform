# A REST API whose routing comes from an OpenAPI document.
#
# Nothing here declares a path. The document is imported and API Gateway builds
# every resource, method, integration, validator and gateway response from it,
# which is what makes the document the thing to review and this file the thing
# that decides how it is deployed.
#
# It is deliberately a separate module from modules/rest-api/ rather than a mode
# of it. An API cannot be both: a body and hand-declared resource and method
# resources both believe they own the same resources, so each apply removes what
# the other created and the API alternates between two shapes. The choice is per
# API and it is made by picking a module.

locals {
  # -------------------------------------------------------------------
  # What the document says
  # -------------------------------------------------------------------
  #
  # The document is decoded here and every check below reads the decoded form,
  # so a claim about the document is a claim about what AWS will be sent rather
  # than a search through its text. The variable's own validation has already
  # refused a document that does not parse, so this cannot fail.
  spec = yamldecode(var.openapi_body)

  spec_version_declared = try(local.spec.openapi, try(local.spec.swagger, null)) != null

  spec_paths = try(local.spec.paths, {})

  # An OpenAPI path item holds operations alongside keys that are not operations
  # -- `parameters`, `summary`, `$ref` -- so the operation set is filtered by
  # method name rather than taken as everything under the path.
  http_methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

  # concat([{}], ...) guards the expansion: merge() with no arguments is an
  # error, which a document with no paths would otherwise produce here instead
  # of at the check that exists to report it.
  operations = merge(concat([{}], [
    for path, item in local.spec_paths : {
      for method, operation in item :
      "${upper(method)} ${path}" => operation
      if contains(local.http_methods, lower(method))
    }
  ])...)

  # -------------------------------------------------------------------
  # Integrations
  # -------------------------------------------------------------------

  integrations = {
    for key, operation in local.operations :
    key => try(operation["x-amazon-apigateway-integration"], null)
  }

  # An operation with no integration is imported as a method with nothing behind
  # it. The route is in the console, the import reported success, and the call
  # answers 500 -- which is also what a broken handler answers.
  operations_without_an_integration = sort([
    for key, integration in local.integrations : key if integration == null
  ])

  # The function ARNs the document integrates with, read out of the integration
  # URIs rather than accepted as a second list that has to be kept in step.
  # A Lambda integration URI ends functions/<arn>/invocations, so the ARN is in
  # the document and there is no reason to ask for it again.
  document_function_arns = sort(distinct(flatten([
    for key, integration in local.integrations :
    flatten(regexall("functions/(arn:[^/]+:function:[^/]+)/invocations", try(integration.uri, "")))
    if integration != null
  ])))

  # Compared by function name, because a grant may be given either a name or an
  # ARN and an ARN may carry a version or alias qualifier.
  document_function_names = sort(distinct([
    for arn in local.document_function_arns :
    element(split(":", arn), 6)
  ]))

  granted_function_names = sort(distinct([
    for _, grant in var.lambda_integrations :
    startswith(grant.function_name, "arn:") ? element(split(":", grant.function_name), 6) : grant.function_name
  ]))

  functions_without_an_invocation_grant = sort([
    for name in local.document_function_names : name
    if !contains(local.granted_function_names, name)
  ])

  # -------------------------------------------------------------------
  # Authorization
  # -------------------------------------------------------------------

  document_requires_authorization = length(try(local.spec.security, [])) > 0

  # Three states, not two: an operation that names a requirement, one that says
  # nothing and inherits the document's, and one that overrides the document
  # with an empty list. Only the third is open by decision, and an empty list
  # and an absent key are the same value in most readings -- which is why they
  # are separated here.
  operations_declaring_no_authorization = sort([
    for key, operation in local.operations : key
    if(try(operation.security, null) != null && length(operation.security) == 0)
    || (try(operation.security, null) == null && !local.document_requires_authorization)
  ])

  # -------------------------------------------------------------------
  # Validators
  # -------------------------------------------------------------------

  declared_validators = keys(try(local.spec["x-amazon-apigateway-request-validators"], {}))

  referenced_validators = sort(distinct(compact(concat(
    [try(local.spec["x-amazon-apigateway-request-validator"], "")],
    [for _, operation in local.operations : try(operation["x-amazon-apigateway-request-validator"], "")],
  ))))

  # A reference to a validator the document does not declare is a warning at
  # import, so with warnings fatal it stops the apply -- but it stops it with
  # API Gateway's wording, after the API has been created. Naming it here costs
  # nothing and reports which reference was wrong.
  validator_references_naming_no_validator = sort([
    for name in local.referenced_validators : name
    if !contains(local.declared_validators, name)
  ])

  # A declared validator nothing points at validates nothing. The parameters and
  # schemas are still in the document, which is what makes it look enforced.
  unreferenced_validators = sort([
    for name in local.declared_validators : name
    if !contains(local.referenced_validators, name)
  ])

  # -------------------------------------------------------------------
  # Document and configuration agreeing
  # -------------------------------------------------------------------

  # A placeholder that survived the render is a placeholder AWS is asked to
  # serve. templatefile() fails on a name it was not given, so the only way one
  # arrives here is an escaped sequence or a document rendered some other way.
  # Matched on a placeholder SHAPE rather than on any dollar-brace sequence. The
  # shipped document explains the escape by writing $${...} in a comment, which
  # renders to a literal ${...} -- so a guard reading every "${" would refuse the
  # very document it ships with, and refuse it for being correct.
  unresolved_placeholders = length(regexall("\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}", var.openapi_body)) > 0

  document_title = try(local.spec.info.title, null)

  # The document may state the default-endpoint setting too, and in overwrite
  # mode its value is imported before the provider reconciles the configured one
  # over the top. Two sources that disagree resolve in an order nobody reading
  # either file can see, so they are required to agree.
  document_disables_default_endpoint = try(
    local.spec["x-amazon-apigateway-endpoint-configuration"].disableExecuteApiEndpoint,
    null
  )

  default_endpoint_disagreement = (
    local.document_disables_default_endpoint != null
    && tobool(local.document_disables_default_endpoint) != var.disable_default_endpoint
  )

  # -------------------------------------------------------------------
  # Access logging
  # -------------------------------------------------------------------

  access_log_group_name = "/aws/apigateway/${var.name}/${var.stage_name}/access"

  # The fields that separate one cause from another, which is the only thing an
  # access log is for once an API is live. integration.error is here for the
  # same reason it is in every other stage in this repository: without it, a
  # missing invocation grant, a handler that threw and an integration timeout
  # all read as the same 5xx.
  #
  # The certificate fields are the mutual TLS half. API Gateway checks a
  # certificate's issuer against the truststore and its validity period at
  # handshake time; it does not check revocation, and it does not warn when a
  # certificate already in the truststore expires. Which certificate a request
  # arrived with is therefore worth writing down, because nothing else records
  # it. The PEM is deliberately not logged -- it is available as a context
  # variable, and logging it writes a client's whole certificate into CloudWatch
  # on every single request.
  base_log_fields = {
    requestId               = "$context.requestId"
    ip                      = "$context.identity.sourceIp"
    requestTime             = "$context.requestTime"
    httpMethod              = "$context.httpMethod"
    resourcePath            = "$context.resourcePath"
    status                  = "$context.status"
    integrationStatus       = "$context.integration.status"
    integrationErrorMessage = "$context.integration.error"
    integrationLatency      = "$context.integration.latency"
    responseLatency         = "$context.responseLatency"
    callerArn               = "$context.identity.userArn"
    authorizerError         = "$context.authorizer.error"
    errorMessage            = "$context.error.message"
    errorResponseType       = "$context.error.responseType"
    validationError         = "$context.error.validationErrorString"
  }

  client_certificate_fields = {
    clientCertSubject  = "$context.identity.clientCert.subjectDN"
    clientCertIssuer   = "$context.identity.clientCert.issuerDN"
    clientCertSerial   = "$context.identity.clientCert.serialNumber"
    clientCertNotAfter = "$context.identity.clientCert.validity.notAfter"
  }

  access_log_format = jsonencode(merge(
    local.base_log_fields,
    var.log_client_certificate_fields ? local.client_certificate_fields : {},
  ))
}

# ---------------------------------------------------------------------------
# The API
# ---------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "this" {
  name        = var.name
  description = var.description

  body = var.openapi_body

  # Warnings are fatal. Left at the service default of false, a document with an
  # unrecognised extension key or an integration API Gateway cannot make sense
  # of is imported minus the parts it could not understand: the apply succeeds
  # and the operation is not there.
  fail_on_warnings = var.fail_on_warnings

  put_rest_api_mode = var.put_rest_api_mode

  disable_execute_api_endpoint = var.disable_default_endpoint

  binary_media_types       = var.binary_media_types
  minimum_compression_size = var.minimum_compression_size == null ? null : tostring(var.minimum_compression_size)

  endpoint_configuration {
    types = [var.endpoint_type]
  }

  tags = var.tags
}

# Every check on the document lives here rather than on the API.
#
# A precondition becomes part of the dependencies of the resource that carries
# it, so a check reading the document from the API resource would make the API's
# identifier depend on the document -- and the deployment, the stage and every
# grant below need that identifier. The same reason the route-table guards in
# modules/http-api/ sit on a node of their own.
resource "terraform_data" "document" {
  input = sha1(var.openapi_body)

  lifecycle {
    precondition {
      condition     = !local.unresolved_placeholders
      error_message = "The rendered document still contains a $${...} sequence. Placeholders are substituted before the document reaches AWS, so one that survives is imported literally -- an integration URI naming no function, or a title nobody chose."
    }

    precondition {
      condition     = local.spec_version_declared
      error_message = "The document declares neither `openapi` nor `swagger`. API Gateway uses that key to decide which specification it is reading, and refuses a document without one."
    }

    precondition {
      condition     = length(local.spec_paths) > 0
      error_message = "The document declares no paths. The import succeeds and produces an API with nothing to call, which is indistinguishable from an API whose paths were dropped."
    }

    precondition {
      condition = length(local.operations_without_an_integration) == 0
      error_message = format(
        "These operations carry no x-amazon-apigateway-integration: %s. Each one is imported as a method with nothing behind it, which answers 500 -- the same answer a handler that threw gives, so the cause is not in the response.",
        join(", ", local.operations_without_an_integration)
      )
    }

    precondition {
      condition = length(local.validator_references_naming_no_validator) == 0
      error_message = format(
        "These request-validator references name a validator the document does not declare: %s. Declared validators are: %s.",
        join(", ", local.validator_references_naming_no_validator),
        length(local.declared_validators) == 0 ? "none" : join(", ", local.declared_validators)
      )
    }

    precondition {
      condition = !local.default_endpoint_disagreement
      error_message = format(
        "The document sets disableExecuteApiEndpoint to %s and disable_default_endpoint is %s. Both are applied -- the document at import, the configuration in the reconciliation afterwards -- so which one wins is decided by an order that is not visible in either file.",
        local.document_disables_default_endpoint,
        var.disable_default_endpoint
      )
    }
  }
}

# ---------------------------------------------------------------------------
# Invocation grants
# ---------------------------------------------------------------------------

# Importing a document does not create these, and neither does anything else.
# Creating an integration in the console attaches the grant as a side effect,
# which is why an API that worked when it was clicked together stops working
# when the same integration arrives from a document.
resource "aws_lambda_permission" "integrations" {
  for_each = var.lambda_integrations

  statement_id  = "AllowAPIGateway-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "apigateway.amazonaws.com"

  # The stage is named so a grant for one stage does not admit another, and the
  # method and path are appended so a grant can be narrowed to the route that
  # needs it. A path variable has to be wildcarded: a grant naming a literal
  # {orderId} matches a request for that exact string and nothing else.
  source_arn = format(
    "%s/%s/%s%s",
    aws_api_gateway_rest_api.this.execution_arn,
    var.stage_name,
    each.value.http_method,
    each.value.path == "/*" ? "/*" : replace(each.value.path, "/\\{[^}]*\\}/", "*")
  )
}

# ---------------------------------------------------------------------------
# Deployment and stage
# ---------------------------------------------------------------------------

# Importing a document changes the API. It does not change what is served: the
# stage keeps the deployment it was given, so a route added to the document
# appears in the console and answers {"message":"Not Found"} until a deployment
# captures it.
#
# The trigger is a hash of the rendered document and of every literal property
# an import in overwrite mode can move, so any change that alters what the API
# is produces a new deployment. create_before_destroy is what stops the stage
# pointing at a deployment being removed.
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      var.openapi_body,
      var.put_rest_api_mode,
      var.endpoint_type,
      var.disable_default_endpoint,
      var.binary_media_types,
      var.minimum_compression_size,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [terraform_data.document]
}

resource "aws_cloudwatch_log_group" "access" {
  name              = local.access_log_group_name
  retention_in_days = var.access_log_retention_days
  kms_key_id        = var.access_log_kms_key_arn

  tags = var.tags
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name

  xray_tracing_enabled = var.xray_tracing_enabled

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format          = local.access_log_format
  }

  tags = var.tags
}

resource "aws_api_gateway_method_settings" "stage_default" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = var.metrics_enabled

    # -1 is how API Gateway is told a limit is unset. Zero is a limit of zero
    # requests, which refuses everything.
    throttling_rate_limit  = var.stage_throttle == null ? -1 : var.stage_throttle.rate_limit
    throttling_burst_limit = var.stage_throttle == null ? -1 : var.stage_throttle.burst_limit
  }
}
