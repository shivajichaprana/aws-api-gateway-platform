#!/usr/bin/env python3
"""Check every OpenAPI document in this repository, without a test runner.

The pipeline runs this as its own gate rather than only through pytest. A check
that works when a test runner is configured stops running the first time the
environment changes, and an import gate is exactly the thing that has to keep
working.

The rules come from ``openapi_rules``, so this and the suite cannot reach
different conclusions about the same file.

Exit status is 1 on any problem, and 1 on finding no documents at all: a run
that discovers nothing to check exits zero and proves nothing.
"""

from __future__ import annotations

import pathlib
import re
import sys

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import openapi_rules as rules  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCUMENTS = sorted(ROOT.glob("openapi/*.y*ml"))

# A placeholder is ${name}; $${name} is an escape that renders to a literal and
# is not one. The escape is collapsed first, so nothing is substituted into it.
PLACEHOLDER = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)\}")

# Values chosen to keep the rendered document meaningful: a timeout that is a
# number, an ARN shaped like an ARN. A blanket string would make the timeout
# check vacuous rather than failing it.
SAMPLES = {
    "integration_timeout_ms": "29000",
    "disable_execute_api_endpoint": "true",
    "partition": "aws",
    "aws_region": "us-east-1",
}
DEFAULT_SAMPLE = "placeholder"


def render(text: str) -> str:
    text = text.replace("$${", "\x00{")
    text = PLACEHOLDER.sub(lambda m: SAMPLES.get(m.group(1), DEFAULT_SAMPLE), text)
    return text.replace("\x00{", "${")


def check(path: pathlib.Path) -> list:
    try:
        spec = yaml.safe_load(render(path.read_text()))
    except yaml.YAMLError as error:
        return [f"the document does not parse once rendered: {error}"]

    if not isinstance(spec, dict):
        return ["the document is not a mapping"]

    problems = []
    if not str(spec.get("openapi", "")).startswith("3."):
        problems.append("the document does not declare an OpenAPI 3 version")

    for rule in rules.ALL_RULES:
        problems.extend(rule(spec))
    return problems


def main() -> int:
    if not DOCUMENTS:
        print("lint-openapi: no documents found under openapi/ -- nothing was checked")
        return 1

    failures = 0
    for path in DOCUMENTS:
        problems = check(path)
        name = path.relative_to(ROOT)
        if problems:
            failures += len(problems)
            print(f"lint-openapi: {name}")
            for problem in problems:
                print(f"  - {problem}")
        else:
            print(f"lint-openapi: {name} OK")

    print(f"lint-openapi: {len(DOCUMENTS)} document(s), {failures} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
