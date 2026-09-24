"""The rules an imported OpenAPI document has to satisfy, in one place.

Shared by the pytest suite and by the standalone gate, so the two cannot come
to different conclusions about the same file. Each rule returns a list of
problems; an empty list is a pass.

These are not general OpenAPI rules. They are the things API Gateway accepts at
import and then does not do -- an operation with no integration, a proxy
integration invoked with the caller's method, a validator that is declared and
never attached. Every one of them produces a deployed API that answers wrongly
rather than a failed apply.
"""

from __future__ import annotations

from typing import Any, Dict, List

INTEGRATION = "x-amazon-apigateway-integration"
VALIDATOR = "x-amazon-apigateway-request-validator"
VALIDATORS = "x-amazon-apigateway-request-validators"

HTTP_METHODS = {"get", "put", "post", "delete", "options", "head", "patch", "trace"}


def operations(spec: Dict[str, Any]):
    for path, item in (spec.get("paths") or {}).items():
        for method, operation in (item or {}).items():
            if method.lower() in HTTP_METHODS:
                yield path, method.lower(), operation


def _where(path: str, method: str) -> str:
    return f"{method.upper()} {path}"


def every_operation_has_an_integration(spec) -> List[str]:
    """An operation without one imports as a method with nothing behind it.

    It answers 500, and the response says nothing about why.
    """
    return [
        f"{_where(path, method)} declares no {INTEGRATION}"
        for path, method, operation in operations(spec)
        if INTEGRATION not in (operation or {})
    ]


def proxy_integrations_are_invoked_with_post(spec) -> List[str]:
    """A proxy integration is always invoked with POST.

    ``httpMethod`` here is the integration's request to Lambda, not the
    caller's request to the API. Setting it to the caller's method is accepted
    at import and answers 500 on every single call.
    """
    problems = []
    for path, method, operation in operations(spec):
        integration = (operation or {}).get(INTEGRATION) or {}
        if integration.get("type") in {"aws_proxy", "aws"}:
            if integration.get("httpMethod") != "POST":
                problems.append(
                    f"{_where(path, method)} invokes its integration with "
                    f"{integration.get('httpMethod')!r}, but a Lambda integration "
                    "is always invoked with POST"
                )
    return problems


def integrations_name_a_type(spec) -> List[str]:
    problems = []
    for path, method, operation in operations(spec):
        integration = (operation or {}).get(INTEGRATION) or {}
        if not integration.get("type"):
            problems.append(f"{_where(path, method)} has an integration with no type")
    return problems


def every_referenced_validator_is_declared(spec) -> List[str]:
    """A validator named and not declared validates nothing.

    The operation imports, the request is not checked, and a body that does not
    match the schema reaches the integration.
    """
    declared = set(spec.get(VALIDATORS) or {})
    problems = []

    referenced = [(None, None, spec.get(VALIDATOR))]
    for path, method, operation in operations(spec):
        referenced.append((path, method, (operation or {}).get(VALIDATOR)))

    for path, method, name in referenced:
        if name is None:
            continue
        if name not in declared:
            location = "the document" if path is None else _where(path, method)
            problems.append(f"{location} names validator {name!r}, which is not declared")
    return problems


def every_declared_validator_is_used(spec) -> List[str]:
    """One nobody attaches is dead weight that reads as coverage."""
    declared = set(spec.get(VALIDATORS) or {})
    used = {spec.get(VALIDATOR)}
    for _, _, operation in operations(spec):
        used.add((operation or {}).get(VALIDATOR))
    unused = sorted(declared - {name for name in used if name})
    return [f"validator {name!r} is declared and attached to nothing" for name in unused]


def every_ref_resolves(spec) -> List[str]:
    """API Gateway rejects an unresolvable reference at import only when
    warnings are fatal, which they are here -- but the failure names the
    document rather than the reference."""
    problems = []

    def walk(node, trail):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "$ref" and isinstance(value, str):
                    if not value.startswith("#/"):
                        problems.append(f"{trail}: external reference {value!r}")
                        continue
                    target: Any = spec
                    for part in value[2:].split("/"):
                        if not isinstance(target, dict) or part not in target:
                            problems.append(f"{trail}: {value!r} resolves to nothing")
                            break
                        target = target[part]
                else:
                    walk(value, f"{trail}/{key}")
        elif isinstance(node, list):
            for index, item in enumerate(node):
                walk(item, f"{trail}[{index}]")

    walk(spec, "")
    return problems


def required_properties_are_declared(spec) -> List[str]:
    """A schema requiring a property it does not declare rejects every request.

    Request validation is on, so the refusal happens at the edge and the
    message names the schema rather than the mistake in it.
    """
    problems = []

    def walk(node, trail):
        if isinstance(node, dict):
            required = node.get("required")
            properties = node.get("properties")
            if isinstance(required, list) and isinstance(properties, dict):
                for name in required:
                    if name not in properties:
                        problems.append(
                            f"{trail}: required property {name!r} is not declared"
                        )
            for key, value in node.items():
                walk(value, f"{trail}/{key}")
        elif isinstance(node, list):
            for index, item in enumerate(node):
                walk(item, f"{trail}[{index}]")

    walk(spec, "")
    return problems


def integration_parameters_name_a_method_parameter(spec) -> List[str]:
    """The two sides are separate strings and a mismatch is accepted at import.

    The value simply arrives at the function as absent, which reads as a client
    that did not send it.
    """
    problems = []
    for path, item in (spec.get("paths") or {}).items():
        shared = [p for p in (item or {}).get("parameters", []) if isinstance(p, dict)]
        for method, operation in (item or {}).items():
            if method.lower() not in HTTP_METHODS:
                continue
            declared = shared + [
                p for p in (operation or {}).get("parameters", []) if isinstance(p, dict)
            ]
            available = {
                f"method.request.{p.get('in')}.{p.get('name')}" for p in declared
            }
            mappings = ((operation or {}).get(INTEGRATION) or {}).get(
                "requestParameters", {}) or {}
            for target, source in mappings.items():
                if source.startswith("method.request.") and source not in available:
                    problems.append(
                        f"{_where(path, method)}: {target} maps from {source}, "
                        "which the operation does not declare"
                    )
    return problems


def security_schemes_referenced_are_declared(spec) -> List[str]:
    declared = set((spec.get("components") or {}).get("securitySchemes") or {})
    problems = []

    requirements = [(None, None, spec.get("security"))]
    for path, method, operation in operations(spec):
        if "security" in (operation or {}):
            requirements.append((path, method, operation["security"]))

    for path, method, requirement in requirements:
        for entry in requirement or []:
            for name in entry:
                if name not in declared:
                    location = "the document" if path is None else _where(path, method)
                    problems.append(
                        f"{location} requires security scheme {name!r}, "
                        "which is not declared"
                    )
    return problems


def operation_ids_are_present_and_unique(spec) -> List[str]:
    problems = []
    seen: Dict[str, str] = {}
    for path, method, operation in operations(spec):
        identifier = (operation or {}).get("operationId")
        if not identifier:
            problems.append(f"{_where(path, method)} declares no operationId")
            continue
        if identifier in seen:
            problems.append(
                f"operationId {identifier!r} is used by both {seen[identifier]} "
                f"and {_where(path, method)}"
            )
        seen[identifier] = _where(path, method)
    return problems


def path_parameters_are_declared(spec) -> List[str]:
    """A path template naming a parameter nothing declares is not routed to."""
    import re

    problems = []
    for path, item in (spec.get("paths") or {}).items():
        templated = set(re.findall(r"\{([^}]+)\}", path))
        shared = {
            p.get("name") for p in (item or {}).get("parameters", [])
            if isinstance(p, dict) and p.get("in") == "path"
        }
        for method, operation in (item or {}).items():
            if method.lower() not in HTTP_METHODS:
                continue
            own = {
                p.get("name") for p in (operation or {}).get("parameters", [])
                if isinstance(p, dict) and p.get("in") == "path"
            }
            missing = templated - shared - own
            if missing:
                problems.append(
                    f"{_where(path, method)}: path parameters {sorted(missing)} "
                    "are in the template and not declared"
                )
    return problems


def open_operations_are_deliberate(spec, expected: List[str]) -> List[str]:
    """An operation overriding the document requirement with an empty list.

    That is right for a liveness probe and wrong everywhere else, so the set is
    compared against a list somebody wrote down rather than merely reported.
    """
    found = sorted(
        _where(path, method)
        for path, method, operation in operations(spec)
        if (operation or {}).get("security") == []
    )
    if found == sorted(expected):
        return []
    return [f"operations without authorization are {found}, expected {sorted(expected)}"]


ALL_RULES = [
    every_operation_has_an_integration,
    proxy_integrations_are_invoked_with_post,
    integrations_name_a_type,
    every_referenced_validator_is_declared,
    every_declared_validator_is_used,
    every_ref_resolves,
    required_properties_are_declared,
    integration_parameters_name_a_method_parameter,
    security_schemes_referenced_are_declared,
    operation_ids_are_present_and_unique,
    path_parameters_are_declared,
]
