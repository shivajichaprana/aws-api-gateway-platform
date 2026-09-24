"""Readers for the parts of the repository the tests make claims about.

Every reader here either returns what it recognises or RAISES. None of them
falls back to a default shape, because a reader that quietly returns nothing
turns a test into an assertion about an empty set -- which passes, and proves
nothing. A rename that these cannot parse is meant to fail here rather than
somewhere that reads as a different problem.
"""

from __future__ import annotations

import ast
import pathlib
import re
from typing import Any, Dict, List, Set

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
AUTHORIZERS = ROOT / "modules" / "authorizers"
HANDLER = AUTHORIZERS / "function" / "handler.py"


class Unreadable(Exception):
    """The file is not in the shape this reader recognises."""


# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------


def _strip_comments(text: str) -> str:
    """Drop whole-line ``#`` comments.

    Comments in these files restate the prose, so a claim checked against the
    raw text can be satisfied by the sentence explaining why the thing is
    absent. Only whole-line comments are removed: a ``#`` inside a string is
    left alone, and there are none trailing code in this tree.
    """
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def _balanced_block(text: str, start: int) -> str:
    """Return the ``{...}`` block beginning at or after ``start``."""
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1: index]
    raise Unreadable("unbalanced block")


def lambda_environment_variables() -> Dict[str, str]:
    """The environment the module gives the bundled authorizer function.

    Read from ``environment { variables = { ... } }`` on the function resource,
    which is the only place that environment is declared.
    """
    text = _strip_comments((AUTHORIZERS / "main.tf").read_text())
    marker = text.find('resource "aws_lambda_function" "scope_enforcer"')
    if marker < 0:
        raise Unreadable("the bundled authorizer function resource was renamed")

    resource = _balanced_block(text, marker)
    env_marker = resource.find("environment")
    if env_marker < 0:
        raise Unreadable("the function declares no environment block")

    variables = _balanced_block(_balanced_block(resource, env_marker), 0)
    found = {}
    for line in variables.splitlines():
        match = re.match(r"\s*([A-Z][A-Z0-9_]*)\s*=\s*(.+?)\s*$", line)
        if match:
            found[match.group(1)] = match.group(2)
    if not found:
        raise Unreadable("no environment variables were recognised")
    return found


def variable_validation_messages(path: pathlib.Path) -> List[str]:
    return re.findall(r"error_message\s*=\s*\"((?:[^\"\\]|\\.)*)\"", path.read_text())


def variable_block(path: pathlib.Path, name: str) -> str:
    text = path.read_text()
    marker = text.find(f'variable "{name}"')
    if marker < 0:
        raise Unreadable(f"variable {name!r} is not declared in {path.name}")
    return _balanced_block(text, marker)


_NULL_GUARD = re.compile(r"([A-Za-z_][\w.]*)\s*(==|!=)\s*null\s*(\|\||&&)")


def _blank_error_swallowing_calls(text: str) -> str:
    """Blank out ``can(...)`` and ``try(...)`` spans.

    Both catch the error their argument raises, so a null reaching one of them
    is answered rather than fatal. Anything outside them is not.
    """
    out = list(text)
    for match in re.finditer(r"\b(can|try)\s*\(", text):
        depth = 0
        for index in range(match.end() - 1, len(text)):
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
                if depth == 0:
                    for position in range(match.start(), index + 1):
                        out[position] = " "
                    break
    return "".join(out)


def unsafe_null_guards() -> List[str]:
    """Null guards written with a logical operator that will still be evaluated.

    Terraform's ``&&`` and ``||`` are NOT short-circuiting -- only the
    conditional operator is. So ``x == null || f(x)`` evaluates ``f(null)`` and
    fails with a message about the argument rather than about the guard, and
    ``x != null && x > 0`` compares null. The guard reads as protecting the
    expression beside it and does not.

    A comparison against null on the far side is safe (equality accepts null),
    and so is anything inside ``can()`` or ``try()``.
    """
    problems = []
    for path in sorted(ROOT.rglob("*.tf")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for match in _NULL_GUARD.finditer(line):
                subject, comparison, operator = match.groups()
                if (comparison, operator) not in (("==", "||"), ("!=", "&&")):
                    continue
                guarded = _blank_error_swallowing_calls(line[match.end():])
                if subject not in guarded:
                    continue
                tail = guarded[guarded.index(subject) + len(subject):]
                if re.match(r"\s*(==|!=)\s*", tail):
                    continue
                problems.append(
                    f"{path.relative_to(ROOT)}:{number}: "
                    f"{subject} is guarded with {operator}, which does not "
                    f"short-circuit -- use a conditional"
                )
    return problems


def terraform_directories() -> List[pathlib.Path]:
    """Every directory holding Terraform, root first.

    Discovered rather than listed, so a module added later is covered by the
    checks that iterate this without anyone remembering to add it.
    """
    directories = {path.parent for path in ROOT.rglob("*.tf")}
    return [ROOT] + sorted(d for d in directories if d != ROOT)


# ---------------------------------------------------------------------------
# The authorizer function
# ---------------------------------------------------------------------------

_ENV_READERS = {"_env", "_int_env", "_json_env"}


def handler_environment_reads() -> Set[str]:
    """Environment variable names the function reads, from its syntax tree.

    Parsed rather than matched: a name built by concatenation or read through
    ``os.environ`` directly would not be found by a regex over the source and
    would be found here as a read this cannot resolve, which raises.
    """
    tree = ast.parse(HANDLER.read_text())
    names: Set[str] = set()

    # The helpers themselves call one another with a name held in a parameter,
    # so their own bodies are skipped. Everywhere else a read must name a
    # literal: one assembled at runtime could not be compared against what
    # Terraform sets, and is refused rather than ignored.
    definitions = {
        node for node in ast.walk(tree)
        if isinstance(node, ast.FunctionDef) and node.name in _ENV_READERS
    }
    inside_helpers = {
        child for definition in definitions for child in ast.walk(definition)
    }

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or node in inside_helpers:
            continue
        function = node.func
        if isinstance(function, ast.Name) and function.id in _ENV_READERS:
            if not node.args or not isinstance(node.args[0], ast.Constant):
                raise Unreadable(
                    "an environment read does not name a literal variable"
                )
            names.add(node.args[0].value)

    if not names:
        raise Unreadable("the function reads no environment variables")
    return names


def handler_module_docstring() -> str:
    return ast.get_docstring(ast.parse(HANDLER.read_text())) or ""


# ---------------------------------------------------------------------------
# The OpenAPI document
# ---------------------------------------------------------------------------

DOCUMENT = ROOT / "openapi" / "orders-api.yaml"

# What the root configuration passes to templatefile(). Read from the tree
# rather than restated, so a placeholder added to the document without being
# supplied is a failure here instead of at the first plan.
_TEMPLATE_CALL = re.compile(
    r"openapi_body\s*=\s*templatefile\([^,]+,\s*\{(.*?)\n\s*\}\)", re.S
)


def template_variables_supplied() -> Set[str]:
    match = _TEMPLATE_CALL.search((ROOT / "main.tf").read_text())
    if not match:
        raise Unreadable("the templatefile call for the document was not found")
    names = set(re.findall(r"^\s*([a-z_][a-z0-9_]*)\s*=", match.group(1), re.M))
    if not names:
        raise Unreadable("the templatefile call supplies no variables")
    return names


# A placeholder is ${name}. An escaped sequence is $${name}, which renders to a
# literal ${name} and is NOT a placeholder -- the document explains its own
# escaping rule by writing one, so a pattern that reads every dollar-brace
# sequence finds a placeholder in a comment that is deliberately not one.
_PLACEHOLDER = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def template_variables_used(text: str = "") -> Set[str]:
    source = text or DOCUMENT.read_text()
    source = source.replace("$${", "\x00{")
    return set(_PLACEHOLDER.findall(source))


SAMPLE_VALUES = {
    "api_title": "orders-api",
    "partition": "aws",
    "aws_region": "us-east-1",
    "orders_function_arn": (
        "arn:aws:lambda:us-east-1:123456789012:function:orders"
    ),
    "integration_timeout_ms": "29000",
    "disable_execute_api_endpoint": "true",
}


def render_document(values: Dict[str, str] = None) -> str:
    """Render the document the way ``templatefile`` would.

    ``$${x}`` collapses to a literal ``${x}``; ``${x}`` is replaced. Doing it in
    that order matters: replacing placeholders first would substitute into the
    escaped sequence and produce something the escape exists to prevent.
    """
    supplied = dict(SAMPLE_VALUES if values is None else values)
    missing = template_variables_used() - set(supplied)
    if missing:
        raise Unreadable(f"no sample value for {sorted(missing)}")

    text = DOCUMENT.read_text().replace("$${", "\x00{")
    text = _PLACEHOLDER.sub(lambda m: str(supplied[m.group(1)]), text)
    return text.replace("\x00{", "${")


def parsed_document(values: Dict[str, str] = None) -> Dict[str, Any]:
    return yaml.safe_load(render_document(values))


HTTP_METHODS = {"get", "put", "post", "delete", "options", "head", "patch", "trace"}


def operations(spec: Dict[str, Any]):
    """Yield ``(path, method, operation)`` for every operation in the document."""
    for path, item in (spec.get("paths") or {}).items():
        for method, operation in (item or {}).items():
            if method.lower() in HTTP_METHODS:
                yield path, method.lower(), operation
