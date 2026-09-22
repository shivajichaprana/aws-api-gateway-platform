# A regional web ACL for an API Gateway stage.
#
# The scope is not an input. A web ACL is created either REGIONAL or
# CLOUDFRONT, the two are not interchangeable, and an API Gateway stage only
# accepts a REGIONAL one in the API's own region. That holds even for an
# edge-optimized API: the CloudFront distribution in front of it is created and
# owned by API Gateway, so there is nothing there to attach a CLOUDFRONT ACL
# to. Offering the choice would only make the wrong one reachable.

locals {
  create_allow_list = length(var.allowed_ip_addresses) > 0
  create_block_list = length(var.blocked_ip_addresses) > 0
  create_rate_rule  = var.rate_limit_per_five_minutes != null

  # A metric name has a narrower character set than a rule name, so both are
  # derived from the same string rather than typed twice.
  metric_prefix = replace(var.name, "-", "_")

  # Every rule that will exist, with its priority, so uniqueness and ordering
  # can be checked before anything is created. A duplicate priority is refused
  # by the service; a block rule sitting behind an allow rule is accepted, and
  # never runs.
  rule_priorities = merge(
    local.create_allow_list ? { "allow-list" = var.allow_list_priority } : {},
    local.create_block_list ? { "block-list" = var.block_list_priority } : {},
    local.create_rate_rule ? { "rate-limit" = var.rate_limit_priority } : {},
    { for key, group in var.managed_rule_groups : key => group.priority },
  )

  duplicate_priorities = sort([
    for priority in distinct(values(local.rule_priorities)) : tostring(priority)
    if length([for _, p in local.rule_priorities : p if p == priority]) > 1
  ])

  # Evaluation stops at the first terminating action, so a rule whose priority
  # number is higher than an allow rule's is only reached by requests that
  # allow rule did not match. That is exactly what an address allow-list is
  # for, which is why this is reported rather than refused: the arrangement is
  # intentional and its consequence is still worth stating.
  allow_rule_priority = local.create_allow_list ? var.allow_list_priority : null

  rules_shadowed_by_an_earlier_allow = local.create_allow_list ? sort([
    for key, priority in local.rule_priorities : key
    if key != "allow-list" && priority > local.allow_rule_priority
  ]) : []

  # Capacity is charged at the group's own immutable setting, so the total a
  # web ACL will consume is known before it is created -- for the groups whose
  # owner published a number and the caller passed it on. A group that declared
  # none is left out of the sum rather than assumed to be free.
  groups_with_capacity = {
    for key, group in var.managed_rule_groups : key => group.capacity
    if group.capacity != null
  }

  groups_without_capacity = sort([
    for key, group in var.managed_rule_groups : key if group.capacity == null
  ])

  declared_capacity = sum(concat([0], values(local.groups_with_capacity)))

  enforced_groups_not_declared = sort([
    for key in var.enforced_rule_groups : key
    if !contains(keys(var.managed_rule_groups), key)
  ])

  counting_groups = sort([
    for key, _ in var.managed_rule_groups : key
    if !contains(tolist(var.enforced_rule_groups), key)
  ])

  # AWS WAF refuses a logging destination whose name does not begin with this
  # prefix, and refuses it at the point the logging configuration is created,
  # which is after the log group already exists. Deriving the name removes the
  # failure rather than validating it.
  log_group_name = "aws-waf-logs-${var.name}"
}

# ---------------------------------------------------------------------------
# Address lists
# ---------------------------------------------------------------------------

resource "aws_wafv2_ip_set" "allow" {
  count = local.create_allow_list ? 1 : 0

  name               = "${var.name}-allow"
  description        = "Addresses admitted ahead of every other rule in ${var.name}"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.allowed_ip_addresses

  tags = var.tags
}

resource "aws_wafv2_ip_set" "block" {
  count = local.create_block_list ? 1 : 0

  name               = "${var.name}-block"
  description        = "Addresses refused by ${var.name}"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.blocked_ip_addresses

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Web ACL
# ---------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = var.description
  scope       = "REGIONAL"

  default_action {
    dynamic "allow" {
      for_each = var.default_action == "allow" ? toset([1]) : toset([])
      content {}
    }

    dynamic "block" {
      for_each = var.default_action == "block" ? toset([1]) : toset([])
      content {}
    }
  }

  dynamic "rule" {
    for_each = local.create_allow_list ? toset([1]) : toset([])

    content {
      name     = "${var.name}-allow-list"
      priority = var.allow_list_priority

      action {
        allow {}
      }

      statement {
        ip_set_reference_statement {
          arn = one(aws_wafv2_ip_set.allow[*].arn)
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric_prefix}_allow_list"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = local.create_block_list ? toset([1]) : toset([])

    content {
      name     = "${var.name}-block-list"
      priority = var.block_list_priority

      action {
        block {}
      }

      statement {
        ip_set_reference_statement {
          arn = one(aws_wafv2_ip_set.block[*].arn)
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric_prefix}_block_list"
        sampled_requests_enabled   = true
      }
    }
  }

  # The limit is counted over the service's five-minute evaluation window, not
  # per second. evaluation_window_sec would make that adjustable and does not
  # exist across the whole provider range this repository pins, so the window
  # stays where the service puts it and the input says so in its own name.
  dynamic "rule" {
    for_each = local.create_rate_rule ? toset([1]) : toset([])

    content {
      name     = "${var.name}-rate-limit"
      priority = var.rate_limit_priority

      action {
        dynamic "block" {
          for_each = var.rate_limit_action == "block" ? toset([1]) : toset([])
          content {}
        }

        dynamic "count" {
          for_each = var.rate_limit_action == "count" ? toset([1]) : toset([])
          content {}
        }

        dynamic "captcha" {
          for_each = var.rate_limit_action == "captcha" ? toset([1]) : toset([])
          content {}
        }

        dynamic "challenge" {
          for_each = var.rate_limit_action == "challenge" ? toset([1]) : toset([])
          content {}
        }
      }

      statement {
        rate_based_statement {
          limit              = var.rate_limit_per_five_minutes
          aggregate_key_type = var.rate_limit_aggregate_key_type

          dynamic "forwarded_ip_config" {
            for_each = var.rate_limit_aggregate_key_type == "FORWARDED_IP" ? toset([1]) : toset([])

            content {
              # A request that arrives without the header cannot be counted
              # against an address, and MATCH would treat every such request as
              # the same source. NO_MATCH leaves them to the rules behind this
              # one instead of collapsing them into one bucket.
              fallback_behavior = "NO_MATCH"
              header_name       = var.rate_limit_forwarded_ip_header
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric_prefix}_rate_limit"
        sampled_requests_enabled   = true
      }
    }
  }

  # A rule whose statement is a managed rule group carries override_action and
  # never action: the group's own rules decide what to do, and this only says
  # whether they are allowed to do it. Writing action here is refused, and
  # writing override_action on an ordinary rule is refused the same way, which
  # is why neither is an input.
  dynamic "rule" {
    for_each = var.managed_rule_groups

    content {
      name     = "${var.name}-${rule.key}"
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = contains(tolist(var.enforced_rule_groups), rule.key) ? toset([1]) : toset([])
          content {}
        }

        dynamic "count" {
          for_each = contains(tolist(var.enforced_rule_groups), rule.key) ? toset([]) : toset([1])
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = rule.value.vendor_name
          version     = rule.value.version

          dynamic "rule_action_override" {
            for_each = rule.value.rule_action_overrides

            content {
              name = rule_action_override.key

              action_to_use {
                dynamic "allow" {
                  for_each = rule_action_override.value == "allow" ? toset([1]) : toset([])
                  content {}
                }

                dynamic "block" {
                  for_each = rule_action_override.value == "block" ? toset([1]) : toset([])
                  content {}
                }

                dynamic "count" {
                  for_each = rule_action_override.value == "count" ? toset([1]) : toset([])
                  content {}
                }

                dynamic "captcha" {
                  for_each = rule_action_override.value == "captcha" ? toset([1]) : toset([])
                  content {}
                }

                dynamic "challenge" {
                  for_each = rule_action_override.value == "challenge" ? toset([1]) : toset([])
                  content {}
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.metric_prefix}_${replace(rule.key, "-", "_")}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.metric_prefix}_default"
    sampled_requests_enabled   = true
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = length(local.duplicate_priorities) == 0
      error_message = format(
        "These rule priorities are used more than once: %s. AWS WAF evaluates rules in priority order and requires each priority to be unique within a web ACL.",
        join(", ", local.duplicate_priorities)
      )
    }

    precondition {
      condition = length(local.enforced_groups_not_declared) == 0
      error_message = format(
        "enforced_rule_groups names groups that are not declared in managed_rule_groups: %s. A name that matches nothing arms nothing, and reads exactly like one that does.",
        join(", ", local.enforced_groups_not_declared)
      )
    }

    precondition {
      condition = local.declared_capacity <= var.capacity_budget
      error_message = format(
        "The managed rule groups that declared a capacity add up to %d WCUs, which is over the budget of %d. A web ACL that exceeds its capacity is refused when it is created, after every rule in it looks correct.",
        local.declared_capacity,
        var.capacity_budget
      )
    }
  }
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_logging ? 1 : 0

  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count = var.enable_logging ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [one(aws_cloudwatch_log_group.waf[*].arn)]

  dynamic "redacted_fields" {
    for_each = toset(var.redacted_headers)

    content {
      single_header {
        name = redacted_fields.value
      }
    }
  }

  dynamic "logging_filter" {
    for_each = var.log_only_non_default_actions ? toset([1]) : toset([])

    content {
      default_behavior = "DROP"

      filter {
        behavior    = "KEEP"
        requirement = "MEETS_ANY"

        condition {
          action_condition {
            action = "BLOCK"
          }
        }

        condition {
          action_condition {
            action = "COUNT"
          }
        }

        condition {
          action_condition {
            action = "CAPTCHA"
          }
        }

        condition {
          action_condition {
            action = "CHALLENGE"
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition = !(var.log_only_non_default_actions && length(local.counting_groups) > 0)
      error_message = format(
        "log_only_non_default_actions drops every record for a request the default action handled, and these managed rule groups are still counting rather than enforcing: %s. A group in count mode does not terminate a request, so its findings are exactly the records that filter discards -- the ACL would appear to be protecting the API and write down nothing about what it found. Enforce the groups first, or leave the filter off while they count.",
        join(", ", local.counting_groups)
      )
    }
  }
}
