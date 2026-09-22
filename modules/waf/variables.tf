variable "name" {
  description = <<-EOT
    Name of the web ACL. The log group this module creates is derived from it,
    and AWS WAF only accepts a logging destination whose name begins with
    aws-waf-logs-, so the prefix is added here rather than left to the caller.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.name))
    error_message = "name must be 3-40 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "description" {
  description = "Description recorded on the web ACL."
  type        = string
  default     = "Regional web ACL protecting an API Gateway stage"
}

variable "default_action" {
  description = <<-EOT
    What happens to a request no rule matched. allow is the usual choice for an
    API behind other authorization; block turns the ACL into an allow-list and
    means a request has to be matched by an allow rule to get through at all.
  EOT
  type        = string
  default     = "allow"

  validation {
    condition     = contains(["allow", "block"], var.default_action)
    error_message = "default_action must be allow or block."
  }
}

# ---------------------------------------------------------------------------
# Managed rule groups
# ---------------------------------------------------------------------------

variable "managed_rule_groups" {
  description = <<-EOT
    AWS-managed rule groups to evaluate, keyed by a name used for the rule and
    its metric. Every group is evaluated in priority order and the first
    terminating action wins, so priorities decide behaviour rather than
    presentation.

    capacity is the group's immutable WCU cost. It is optional because the
    authoritative value belongs to the group's owner and is read with
    `aws wafv2 describe-managed-rule-group`, not guessed here; a group that
    does not declare one is left out of the budget check and named in
    rule_groups_without_declared_capacity, so the checked total is a lower
    bound rather than a claim about the whole ACL.

    rule_action_overrides changes what a single rule inside the group does
    without turning the whole group off, which is the narrow tool for one noisy
    rule. Turning the group to count is the wide one, and that is what
    enforced_rule_groups controls.
  EOT
  type = map(object({
    name                  = string
    vendor_name           = optional(string, "AWS")
    priority              = number
    version               = optional(string)
    capacity              = optional(number)
    rule_action_overrides = optional(map(string), {})
  }))

  default = {
    common = {
      name     = "AWSManagedRulesCommonRuleSet"
      priority = 100
    }
    known-bad-inputs = {
      name     = "AWSManagedRulesKnownBadInputsRuleSet"
      priority = 110
    }
    ip-reputation = {
      name     = "AWSManagedRulesAmazonIpReputationList"
      priority = 120
    }
    sql-injection = {
      name     = "AWSManagedRulesSQLiRuleSet"
      priority = 130
    }
  }

  validation {
    condition = alltrue([
      for k, _ in var.managed_rule_groups : can(regex("^[a-z][a-z0-9-]{0,48}[a-z0-9]$", k))
    ])
    error_message = "Each managed_rule_groups key must be 2-50 characters, lower-case alphanumeric and hyphens, starting with a letter and not ending in a hyphen."
  }

  validation {
    condition = alltrue([
      for _, g in var.managed_rule_groups : g.priority >= 0 && g.priority <= 1000000000
    ])
    error_message = "Each managed rule group priority must be between 0 and 1000000000."
  }

  validation {
    condition = alltrue([
      for _, g in var.managed_rule_groups : g.capacity == null || (g.capacity > 0 && g.capacity <= 5000)
    ])
    error_message = "A declared managed rule group capacity must be between 1 and 5000, which is the maximum capacity of any single rule group."
  }

  validation {
    condition = alltrue(flatten([
      for _, g in var.managed_rule_groups : [
        for _, action in g.rule_action_overrides :
        contains(["allow", "block", "count", "captcha", "challenge"], action)
      ]
    ]))
    error_message = "Each rule_action_overrides value must be one of allow, block, count, captcha or challenge."
  }
}

variable "enforced_rule_groups" {
  description = <<-EOT
    Managed rule groups permitted to block. Empty by default: a rule group
    dropped onto a live API in blocking mode rejects real traffic the first
    time one of its rules is wrong about a request, and which rules are wrong
    about which requests is a property of the workload rather than of the group.

    A group not named here is still evaluated, still labels the request and
    still records a count metric. It simply cannot terminate the request, which
    is what makes the first weeks of an ACL readable rather than an incident.

    rule_groups_not_enforcing reports what is still counting.
  EOT
  type        = set(string)
  default     = []
}

variable "capacity_budget" {
  description = <<-EOT
    Web ACL capacity, in WCUs, this ACL is allowed to declare.

    1500 is what the basic web ACL price includes. AWS permits up to 5000
    without a limit increase, but everything above 1500 is charged, so passing
    the boundary is a billing decision rather than a technical one and is left
    to the caller to take on purpose.
  EOT
  type        = number
  default     = 1500

  validation {
    condition     = var.capacity_budget >= 1 && var.capacity_budget <= 5000
    error_message = "capacity_budget must be between 1 and 5000, which is the maximum capacity of a web ACL."
  }
}

# ---------------------------------------------------------------------------
# Address lists
# ---------------------------------------------------------------------------

variable "allowed_ip_addresses" {
  description = <<-EOT
    Addresses admitted ahead of every other rule, as IPv4 CIDRs. Evaluation
    stops at the first terminating action, so anything listed here is exempt
    from every rule with a higher priority number, including the managed groups.
    That is the point of the list and also its cost.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.allowed_ip_addresses : can(cidrhost(cidr, 0)) && cidr == format("%s/%s", cidrhost(cidr, 0), split("/", cidr)[1])
    ])
    error_message = "Each allowed_ip_addresses entry must be a CIDR in canonical form, such as 203.0.113.0/24 rather than 203.0.113.5/24."
  }
}

variable "blocked_ip_addresses" {
  description = "Addresses refused outright, as IPv4 CIDRs, evaluated after the allow list and before the managed groups."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.blocked_ip_addresses : can(cidrhost(cidr, 0)) && cidr == format("%s/%s", cidrhost(cidr, 0), split("/", cidr)[1])
    ])
    error_message = "Each blocked_ip_addresses entry must be a CIDR in canonical form, such as 203.0.113.0/24 rather than 203.0.113.5/24."
  }
}

variable "allow_list_priority" {
  description = "Priority of the address allow-list rule. Lower numbers are evaluated first."
  type        = number
  default     = 10
}

variable "block_list_priority" {
  description = "Priority of the address block-list rule."
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------

variable "rate_limit_per_five_minutes" {
  description = <<-EOT
    Requests one source address may make in five minutes before the rate-based
    rule blocks it. Null disables the rule.

    The name says five minutes because that is the unit, and it is the single
    most misread number in a web ACL: AWS WAF counts a rate-based rule over an
    evaluation window, not per second. A limit of 2000 is about seven requests
    a second, not two thousand.

    The window is fixed here at the service default of five minutes. Choosing a
    shorter one needs evaluation_window_sec, which does not exist across the
    whole provider range this repository pins, and a configuration that plans
    on some of its allowed providers and not others is worse than one window.

    The floor of 100 is the same intersection. AWS now accepts limits as low as
    10 and the provider accepts 10 from v5.44.0, but at 5.0.0 it validates the
    field at 100 and refuses anything smaller before a request is ever made.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.rate_limit_per_five_minutes == null || (var.rate_limit_per_five_minutes >= 100 && var.rate_limit_per_five_minutes <= 2000000000)
    error_message = "rate_limit_per_five_minutes must be between 100 and 2000000000, or null to disable the rule."
  }
}

variable "rate_limit_priority" {
  description = "Priority of the rate-based rule."
  type        = number
  default     = 30
}

variable "rate_limit_action" {
  description = "What happens to a source over the limit. count records the decision without acting on it, which is how to find out what the limit would have caught."
  type        = string
  default     = "block"

  validation {
    condition     = contains(["block", "count", "captcha", "challenge"], var.rate_limit_action)
    error_message = "rate_limit_action must be block, count, captcha or challenge."
  }
}

variable "rate_limit_aggregate_key_type" {
  description = <<-EOT
    What the rate is counted against. IP uses the address the request arrived
    from; FORWARDED_IP uses an address out of a header and is only meaningful
    behind something that sets one and strips a client-supplied copy.
  EOT
  type        = string
  default     = "IP"

  validation {
    condition     = contains(["IP", "FORWARDED_IP"], var.rate_limit_aggregate_key_type)
    error_message = "rate_limit_aggregate_key_type must be IP or FORWARDED_IP."
  }
}

variable "rate_limit_forwarded_ip_header" {
  description = "Header read when rate_limit_aggregate_key_type is FORWARDED_IP."
  type        = string
  default     = "X-Forwarded-For"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

variable "enable_logging" {
  description = "Send matched-request records to a log group. A web ACL writes nothing anywhere until this is on, so a rule that fired and a rule that never matched look the same."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the web ACL log group."
  type        = number
  default     = 90

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be one of the retention periods CloudWatch Logs accepts."
  }
}

variable "log_kms_key_arn" {
  description = "Customer-managed key for the log group. Its policy must already admit the CloudWatch Logs service principal in this region, or creating the group fails."
  type        = string
  default     = null

  validation {
    condition     = var.log_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.log_kms_key_arn))
    error_message = "log_kms_key_arn must be a KMS key ARN (an alias ARN is not accepted by the log group)."
  }
}

variable "redacted_headers" {
  description = <<-EOT
    Headers removed from the log record. Both defaults carry a credential: a
    web ACL log holds the headers of a request it acted on, so without this an
    API key and a bearer token are written into a log group in clear text, and
    every reader of that group holds them.
  EOT
  type        = list(string)
  default     = ["authorization", "x-api-key"]

  validation {
    condition = alltrue([
      for h in var.redacted_headers : can(regex("^[a-z0-9-_]{1,40}$", h))
    ])
    error_message = "Each redacted_headers entry must be lower case: AWS WAF returns header names in lower case and a mixed-case entry is a permanent difference in the plan."
  }
}

variable "log_only_non_default_actions" {
  description = "Record only requests a rule acted on, dropping the ones that fell through to the default action. An ACL in front of a busy API otherwise logs every request it allows."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to resources this module creates."
  type        = map(string)
  default     = {}
}
