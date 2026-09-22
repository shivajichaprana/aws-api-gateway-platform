output "web_acl_arn" {
  description = "ARN of the web ACL. This is what an API Gateway stage association takes, and its scope segment is what makes a regional ACL distinguishable from a CloudFront one before either is used."
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "Identifier of the web ACL."
  value       = aws_wafv2_web_acl.this.id
}

output "web_acl_name" {
  description = "Name of the web ACL."
  value       = aws_wafv2_web_acl.this.name
}

output "web_acl_capacity" {
  description = "Capacity the web ACL actually consumes, in WCUs, as calculated by AWS WAF once it exists. This is the authoritative figure; declared_capacity is what could be checked before it did."
  value       = aws_wafv2_web_acl.this.capacity
}

output "rule_priorities" {
  description = "Priority of every rule in the ACL, by rule name. Evaluation runs from the lowest number upward and stops at the first terminating action."
  value       = local.rule_priorities
}

output "log_group_name" {
  description = "Log group receiving matched-request records, or null when logging is off."
  value       = var.enable_logging ? local.log_group_name : null
}

output "redacted_headers" {
  description = "Headers removed from each log record. Anything not listed here is written to the log group in full, including any header a client happens to use to carry a credential."
  value       = var.enable_logging ? sort(var.redacted_headers) : []
}

# ---------------------------------------------------------------------------
# What this module did not do
# ---------------------------------------------------------------------------

output "rule_groups_not_enforcing" {
  description = "Managed rule groups evaluated in count mode. Each one still labels requests and still publishes a metric, and none of them can refuse a request. Until this list is empty the ACL is an observation, not a control."
  value       = local.counting_groups
}

output "rule_groups_without_declared_capacity" {
  description = "Managed rule groups whose WCU cost was not declared, so they were left out of the budget check. Read the real figure with `aws wafv2 describe-managed-rule-group`; while this list is non-empty, declared_capacity is a lower bound rather than the ACL's cost."
  value       = local.groups_without_capacity
}

output "declared_capacity" {
  description = "Sum of the capacities that were declared, checked against capacity_budget at plan time. Compare it with web_acl_capacity after an apply to see how much of the ACL it accounted for."
  value       = local.declared_capacity
}

output "capacity_budget" {
  description = "Capacity this ACL was allowed to declare. The basic web ACL price covers 1500 WCUs; everything beyond that is charged, so a budget above it is a billing decision."
  value       = var.capacity_budget
}

output "rules_shadowed_by_an_earlier_allow" {
  description = "Rules evaluated after the address allow-list. A request from a listed address is allowed there and never reaches any of these, so nothing in this list applies to an allow-listed caller -- including the managed rule groups."
  value       = local.rules_shadowed_by_an_earlier_allow
}

output "logging_enabled" {
  description = "Whether the ACL records the requests it acts on. While this is false a rule that fired and a rule that has never matched anything produce the same evidence, which is none."
  value       = var.enable_logging
}

output "rate_limit_window_seconds" {
  description = "Window the rate-based rule counts over, in seconds, or null when there is no rate rule. It is the service default of 300 and is not configurable here, so the limit is that many requests per five minutes rather than per second."
  value       = local.create_rate_rule ? 300 : null
}
