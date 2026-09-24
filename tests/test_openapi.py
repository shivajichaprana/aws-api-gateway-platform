"""The document that IS the API.

Nothing in Terraform declares a path here: the paths in the document are the
paths that exist. API Gateway checks the document's shape at import and almost
nothing about whether it describes a working API, so everything below is a
property that imports cleanly and then answers wrongly.
"""

from __future__ import annotations

import re

import pytest
import yaml

import openapi_rules as rules
import repofiles

# The operations that deliberately require nothing. Written here rather than
# derived, because the whole point is that somebody decided each one.
OPEN_OPERATIONS = ["GET /health"]


@pytest.fixture(scope="module")
def spec():
    return repofiles.parsed_document()


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def test_every_placeholder_the_document_uses_is_supplied():
    """templatefile fails on a name it was not given -- at plan, every time.

    That is the loud direction, and it is still better caught here than by a
    pipeline that has to resolve a provider first.
    """
    used = repofiles.template_variables_used()
    supplied = repofiles.template_variables_supplied()

    assert used - supplied == set(), (
        f"the document uses placeholders nothing supplies: {sorted(used - supplied)}"
    )


def test_every_placeholder_supplied_is_one_the_document_uses():
    """The quiet direction.

    An extra value is accepted in silence, so a placeholder renamed in the
    document leaves the old value being passed to nothing -- and the rename is
    only noticed if the new name happens to be missing too.
    """
    used = repofiles.template_variables_used()
    supplied = repofiles.template_variables_supplied()

    assert supplied - used == set(), (
        f"values are supplied for placeholders nothing uses: {sorted(supplied - used)}"
    )


def test_an_escaped_sequence_survives_rendering_as_a_literal():
    """``$${x}`` renders to ``${x}`` and is not a placeholder.

    The document explains its own escaping rule by writing one, so a reader
    that treats every dollar-brace sequence as a placeholder finds one here
    that deliberately is not.
    """
    source = repofiles.DOCUMENT.read_text()
    assert "$${" in source, "the escaping example was removed from the document"
    assert "$${" not in repofiles.render_document()


def test_nothing_unresolved_survives_rendering(spec):
    rendered = repofiles.render_document()
    leftovers = re.findall(r"(?<!\$)\$\{[A-Za-z_][A-Za-z0-9_]*\}", rendered)
    assert leftovers == []


def test_the_rendered_document_is_openapi_3(spec):
    assert str(spec.get("openapi", "")).startswith("3.")
    assert spec.get("info", {}).get("title")
    assert spec.get("paths")


def test_api_gateway_expressions_pass_through_untouched(spec):
    """``$context.`` and ``$input.`` carry no brace, so the renderer leaves them.

    They are how a gateway response says anything useful at all, and one
    rewritten by the template would be silently replaced or would fail the
    render.
    """
    rendered = repofiles.render_document()
    assert "$context.requestId" in rendered
    assert "$context.error.validationErrorString" in rendered


# ---------------------------------------------------------------------------
# What imports cleanly and does not work
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("rule", rules.ALL_RULES, ids=lambda r: r.__name__)
def test_document_rule(spec, rule):
    problems = rule(spec)
    assert problems == [], "\n".join(problems)


def test_the_open_operations_are_the_ones_written_down(spec):
    assert rules.open_operations_are_deliberate(spec, OPEN_OPERATIONS) == []


def test_the_rules_would_catch_the_thing_they_are_written_for(spec):
    """Each rule is shown rejecting a document that breaks it.

    A rule returning an empty list is indistinguishable from a rule that looks
    at nothing, and this file is the only place that difference is visible.
    """
    import copy

    broken = copy.deepcopy(spec)
    broken["paths"]["/orders"]["get"].pop(rules.INTEGRATION)
    assert rules.every_operation_has_an_integration(broken)

    broken = copy.deepcopy(spec)
    broken["paths"]["/orders"]["get"][rules.INTEGRATION]["httpMethod"] = "GET"
    assert rules.proxy_integrations_are_invoked_with_post(broken)

    broken = copy.deepcopy(spec)
    broken["paths"]["/orders"]["get"][rules.VALIDATOR] = "does-not-exist"
    assert rules.every_referenced_validator_is_declared(broken)

    broken = copy.deepcopy(spec)
    broken[rules.VALIDATORS]["never-attached"] = {"validateRequestBody": True}
    assert rules.every_declared_validator_is_used(broken)

    broken = copy.deepcopy(spec)
    broken["paths"]["/orders"]["get"]["responses"]["200"]["content"][
        "application/json"]["schema"]["$ref"] = "#/components/schemas/Nope"
    assert rules.every_ref_resolves(broken)

    broken = copy.deepcopy(spec)
    broken["components"]["schemas"]["NewOrder"]["required"].append("nosuchfield")
    assert rules.required_properties_are_declared(broken)

    broken = copy.deepcopy(spec)
    broken["paths"]["/orders/{orderId}"]["get"][rules.INTEGRATION][
        "requestParameters"] = {
        "integration.request.path.orderId": "method.request.path.orderID"}
    assert rules.integration_parameters_name_a_method_parameter(broken)

    broken = copy.deepcopy(spec)
    broken["security"] = [{"not-declared": []}]
    assert rules.security_schemes_referenced_are_declared(broken)

    broken = copy.deepcopy(spec)
    broken["paths"]["/orders"]["post"]["operationId"] = "listOrders"
    assert rules.operation_ids_are_present_and_unique(broken)

    broken = copy.deepcopy(spec)
    broken["paths"]["/orders/{orderId}"].pop("parameters")
    assert rules.path_parameters_are_declared(broken)

    broken = copy.deepcopy(spec)
    broken["paths"]["/orders"]["get"]["security"] = []
    assert rules.open_operations_are_deliberate(broken, OPEN_OPERATIONS)


# ---------------------------------------------------------------------------
# Conventions this document keeps on purpose
# ---------------------------------------------------------------------------


def test_the_document_requires_authorization_unless_an_operation_opts_out(spec):
    """Stated at the document level so silence means a signed request.

    A document with no default lets an operation that says nothing about
    authorization require nothing, which is the failure that looks like every
    other working operation.
    """
    assert spec.get("security"), "the document states no default requirement"


def test_a_request_body_is_closed_where_one_is_accepted(spec):
    """``additionalProperties: false`` is what makes validation reject.

    Without it an unexpected field is accepted and passed through, so the
    schema documents the body without constraining it.
    """
    for name in ("NewOrder",):
        schema = spec["components"]["schemas"][name]
        assert schema.get("additionalProperties") is False, (
            f"{name} accepts fields it does not declare"
        )


def test_the_integration_timeout_is_within_the_gateways_own_ceiling(spec):
    """Beyond the ceiling the caller gets a timeout while the work continues.

    It continues, finishes and is billed, so a client retry does it twice.
    """
    for path, method, operation in rules.operations(spec):
        timeout = (operation.get(rules.INTEGRATION) or {}).get("timeoutInMillis")
        if timeout is not None:
            assert 50 <= int(timeout) <= 29000, (
                f"{method.upper()} {path} asks for {timeout}ms"
            )


def test_the_liveness_probe_answers_without_a_backend(spec):
    """It reports that API Gateway is serving the stage, which is the narrow
    claim -- and the honest one for something reachable without credentials."""
    integration = spec["paths"]["/health"]["get"][rules.INTEGRATION]
    assert integration["type"] == "mock"


def test_the_document_is_valid_yaml_before_rendering_too():
    """A template that only parses once rendered hides a syntax error behind a
    substitution, and the render happens at plan rather than in review."""
    placeholder_free = re.sub(r"(?<!\$)\$\{[A-Za-z_][A-Za-z0-9_]*\}", "x",
                              repofiles.DOCUMENT.read_text())
    assert yaml.safe_load(placeholder_free)
