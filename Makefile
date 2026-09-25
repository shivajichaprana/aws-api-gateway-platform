# Every gate the pipeline runs, runnable locally with the same flags.
#
# The point of this file is that `make check` locally and a green pipeline mean
# the same thing. Where a flag matters -- -backend=false, the flake8 rule
# selection, the tflint failure severity -- it is written once, here, and the
# workflow calls the same commands.
#
# Targets are grouped by what they need:
#
#   no credentials : init validate fmt fmt-check lint lint-python openapi-lint
#                    pytest test check
#   credentials    : plan deploy apply destroy output
#
# Nothing in the first group talks to AWS or to a state store, which is what
# lets all of it run on a pull request from a fork.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

TERRAFORM ?= terraform
TFLINT    ?= tflint
PYTHON    ?= python3
PYTEST    ?= $(PYTHON) -m pytest
FLAKE8    ?= $(PYTHON) -m flake8

# Extra flags for a one-off run, e.g. make plan TF_ARGS="-var-file=prod.tfvars".
TF_ARGS ?=

# The root is validated alongside every module. A module validated on its own is
# given no variable values, so its validation conditions are never evaluated --
# the fault appears only where the module is called and a caller leaves a value
# unset, which is the default path. Discovered rather than assumed, so the list
# is derived from the tree instead of maintained by hand.
MODULE_DIRS := $(sort $(patsubst %/,%,$(dir $(wildcard modules/*/versions.tf))))
TF_DIRS     := . $(MODULE_DIRS)

PY_FILES := $(shell git ls-files '*.py' 2>/dev/null)

.PHONY: help
help: ## Show this help
	@printf 'Usage: make <target>\n\n'
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\nNeeds credentials: plan deploy apply destroy output\n'

# ---------------------------------------------------------------------------
# Terraform, without a backend
# ---------------------------------------------------------------------------

.PHONY: init
init: ## terraform init for the root and every module, no backend
	@for dir in $(TF_DIRS); do \
		printf '==> init %s\n' "$$dir"; \
		$(TERRAFORM) -chdir="$$dir" init -backend=false -input=false; \
	done

.PHONY: fmt
fmt: ## Rewrite every file to canonical format
	$(TERRAFORM) fmt -recursive

.PHONY: fmt-check
fmt-check: ## Fail on anything not canonically formatted
	$(TERRAFORM) fmt -check -diff -recursive

.PHONY: validate
validate: fmt-check ## Validate the root and every module separately
	@for dir in $(TF_DIRS); do \
		printf '==> validate %s\n' "$$dir"; \
		$(TERRAFORM) -chdir="$$dir" init -backend=false -input=false >/dev/null; \
		$(TERRAFORM) -chdir="$$dir" validate; \
	done

.PHONY: lint
lint: ## tflint across the tree; warnings report, errors fail
	$(TFLINT) --init
	$(TFLINT) --recursive --minimum-failure-severity=error

# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------

.PHONY: deps
deps: ## Install the test dependencies
	$(PYTHON) -m pip install --upgrade pip
	$(PYTHON) -m pip install -r tests/requirements.txt flake8==7.1.1

.PHONY: lint-python
lint-python: ## Syntax errors, undefined names, style, and a compile check
	$(FLAKE8) --select=E9,F63,F7,F82 --show-source .
	$(FLAKE8) --max-line-length=110 tests modules
	@# The authorizer is deployed as source and compiled on first invocation,
	@# so a syntax error in it is a runtime failure inside somebody's request.
	@for file in $(PY_FILES); do $(PYTHON) -m py_compile "$$file"; done

.PHONY: openapi-lint
openapi-lint: ## Lint the OpenAPI documents on their own
	@# Run outside pytest as well as inside it. A check that only works when a
	@# test runner is configured stops running the first time the environment
	@# changes, and an import gate has to keep working.
	$(PYTHON) tests/lint_openapi.py

.PHONY: pytest
pytest: ## Run the offline suite
	$(PYTEST) tests -q

.PHONY: test
test: lint-python openapi-lint pytest ## Every Python gate

.PHONY: check
check: validate lint test ## Everything that needs no credentials

# ---------------------------------------------------------------------------
# Deployment -- these need credentials
# ---------------------------------------------------------------------------

# A separate init: the targets below use whatever backend is configured, unlike
# the credential-free ones above.
.PHONY: init-backend
init-backend: ## terraform init at the root with its configured backend
	$(TERRAFORM) init -input=false

.PHONY: plan
plan: ## Plan the root configuration into terraform.tfplan
	$(TERRAFORM) plan -input=false -out=terraform.tfplan $(TF_ARGS)

.PHONY: deploy
deploy: ## Plan, show the plan, then apply it after a confirmation
	@$(MAKE) --no-print-directory plan
	@printf '\n'
	@$(TERRAFORM) show terraform.tfplan | tail -n 40
	@printf '\nApply the plan above? [y/N] '
	@read -r reply; [[ "$$reply" == y || "$$reply" == Y ]] || { echo 'Nothing applied.'; exit 1; }
	@# The saved plan is applied, not a fresh one. Applying without it re-plans
	@# against whatever the account looks like now, which is not what was read.
	$(TERRAFORM) apply -input=false terraform.tfplan
	@rm -f terraform.tfplan
	@printf '\nRead these before calling it done:\n'
	@$(MAKE) --no-print-directory findings

.PHONY: apply
apply: ## Apply without the confirmation, for a pipeline
	$(TERRAFORM) apply -input=false -auto-approve $(TF_ARGS)

.PHONY: destroy
destroy: ## Destroy everything this configuration owns
	$(TERRAFORM) destroy -input=false $(TF_ARGS)

.PHONY: output
output: ## Show every output as JSON
	$(TERRAFORM) output -json

# The outputs that report what is NOT the case. An empty list is the assertion
# that an assumption holds; anything else is a finding. They are collected here
# because the ones worth reading after an apply are not the ones worth reading
# during it.
FINDING_OUTPUTS := \
	routes_matching_unlisted_paths \
	lambda_permissions_not_managed \
	integration_cors_headers_discarded \
	authorizers_with_cached_results \
	scope_enforced_routes \
	authorizer_invocations_not_granted \
	methods_not_requiring_an_api_key \
	plans_above_the_stage_throttle \
	waf_rule_groups_not_enforcing \
	waf_rules_shadowed_by_an_earlier_allow \
	openapi_functions_without_an_invocation_grant \
	openapi_operations_declaring_no_authorization \
	mutual_tls_is_bypassable

.PHONY: findings
findings: ## Print the outputs that report what is not the case
	@for name in $(FINDING_OUTPUTS); do \
		value=$$($(TERRAFORM) output -json "$$name" 2>/dev/null || true); \
		[[ -z "$$value" ]] && continue; \
		printf '  %-48s %s\n' "$$name" "$$value"; \
	done

.PHONY: clean
clean: ## Remove local Terraform and Python working files
	rm -f terraform.tfplan
	find . -type d -name .terraform -prune -exec rm -rf {} +
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
	find . -type d -name .pytest_cache -prune -exec rm -rf {} +
