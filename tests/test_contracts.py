"""What two files have to agree about, and nothing does.

Terraform will not tell you that the environment it writes is not the
environment the function reads. Neither will Python, or Lambda, or API Gateway.
A misspelling here produces an authorizer that denies every request for lack of
configuration -- which from outside is a token problem, and sends whoever picks
it up to the identity provider rather than to the two files that disagree.
"""

from __future__ import annotations

import ast
import pathlib
import re
import sys

import pytest

import repofiles
from conftest import authz
from repofiles import AUTHORIZERS, HANDLER, ROOT

MAIN = (AUTHORIZERS / "main.tf").read_text()
VARIABLES = AUTHORIZERS / "variables.tf"


# ---------------------------------------------------------------------------
# The environment
# ---------------------------------------------------------------------------


def test_every_variable_terraform_sets_is_one_the_function_reads():
    written = set(repofiles.lambda_environment_variables())
    read = repofiles.handler_environment_reads()

    assert written - read == set(), (
        "Terraform sets variables the function never reads: "
        f"{sorted(written - read)}"
    )


def test_every_variable_the_function_reads_is_one_terraform_sets():
    """The direction that costs the most.

    A variable the function reads and nothing sets is silently empty. For the
    issuer that is a denial of everything; for the scope map it is every route
    unlisted.
    """
    written = set(repofiles.lambda_environment_variables())
    read = repofiles.handler_environment_reads()

    assert read - written == set(), (
        "the function reads variables Terraform does not set: "
        f"{sorted(read - written)}"
    )


def test_the_log_level_is_read_outside_the_contract_and_has_a_default():
    """The one environment read that is deliberately not wired from Terraform.

    It is asserted rather than assumed, because the two checks above pass if the
    reader simply stops finding it.
    """
    source = HANDLER.read_text()
    assert 'os.environ.get("LOG_LEVEL", "INFO")' in source
    assert "LOG_LEVEL" not in repofiles.lambda_environment_variables()


# ---------------------------------------------------------------------------
# Defaults, stated in two places
# ---------------------------------------------------------------------------


def _handler_default(name):
    """The fallback the function uses when a variable is unset."""
    tree = ast.parse(HANDLER.read_text())
    for node in ast.walk(tree):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id in {"_env", "_int_env", "_json_env"}
                and node.args and isinstance(node.args[0], ast.Constant)
                and node.args[0].value == name):
            if len(node.args) < 2:
                return None
            return ast.literal_eval(node.args[1])
    raise AssertionError(f"the function does not read {name}")


def _terraform_default(field):
    """The default declared for one ``optional()`` field.

    A trailing comment is allowed for. HCL permits one and this reader once did
    not, which made adding a note beside a field look exactly like removing its
    default -- a reader being strict about the wrong thing.
    """
    block = repofiles.variable_block(VARIABLES, "lambda_authorizers")
    match = re.search(
        rf"^\s*{field}\s*=\s*optional\([^,]+,\s*(.+?)\)\s*(?:#.*)?$",
        block, re.M)
    if not match:
        raise AssertionError(f"{field} does not declare a default")
    return match.group(1).strip().strip('"')


@pytest.mark.parametrize("field,variable,convert", [
    ("unlisted_route_action", "UNLISTED_ROUTE_ACTION", str),
    ("jwks_cache_seconds", "JWKS_CACHE_SECONDS", int),
    ("clock_skew_seconds", "CLOCK_SKEW_SECONDS", int),
])
def test_the_two_declared_defaults_agree(field, variable, convert):
    """A default stated in Terraform and a different one in the function means
    the deployed behaviour is whichever one happens to win, and the documented
    one may be neither."""
    assert convert(_terraform_default(field)) == convert(_handler_default(variable))


# ---------------------------------------------------------------------------
# Values one file produces and the other branches on
# ---------------------------------------------------------------------------


def test_the_unlisted_route_actions_are_the_ones_the_function_understands():
    """A third value would be accepted by Terraform and read as ``deny``.

    Failing shut is the right accident to have, but it is still an accident:
    the request is refused and the configuration says it should be allowed.
    """
    block = repofiles.variable_block(VARIABLES, "lambda_authorizers")
    accepted = set(re.findall(
        r'contains\(\["deny", "allow"\], v\.scope_enforcement\.unlisted_route_action\)',
        block))
    assert accepted, "the unlisted_route_action enum was renamed or removed"

    source = HANDLER.read_text()
    assert 'unlisted_action == "allow"' in source


def test_the_route_key_validation_admits_the_functions_fallback_key():
    """``$default`` is the entry the function falls back to.

    A validation that refused it would make the fallback unreachable -- the code
    path would be there, tested, and never taken by any configuration Terraform
    accepts.
    """
    block = repofiles.variable_block(VARIABLES, "lambda_authorizers")
    assert 'rk == "$default"' in block
    assert 'required_by_route.get("$default")' in HANDLER.read_text()


def test_the_route_key_validation_matches_what_the_function_looks_up():
    """Both sides treat a route key as the literal ``$context.routeKey`` string.

    Terraform's pattern is applied here to route keys the function is then asked
    to decide, so a pattern that accepted a shape the lookup cannot match would
    be caught rather than merely looked at.
    """
    block = repofiles.variable_block(VARIABLES, "lambda_authorizers")
    match = re.search(r'can\(regex\("(\^\(GET\|.+?)",\s*rk\)\)', block)
    assert match, "the route-key pattern was renamed"
    pattern = match.group(1).replace("\\\\", "\\")

    accepted = ["GET /orders", "POST /orders", "DELETE /orders/{orderId}",
                "ANY /{proxy+}", "GET /"]
    refused = ["GET/orders", "get /orders", "GET orders", "TRACE /orders",
               "GET  /orders"]

    for key in accepted:
        assert re.match(pattern, key), f"{key!r} is a real route key and was refused"
    for key in refused:
        assert not re.match(pattern, key), f"{key!r} is not a route key and was accepted"


# ---------------------------------------------------------------------------
# The deployed function is the tested function
# ---------------------------------------------------------------------------


def test_the_declared_entrypoint_exists():
    """``handler.handler`` names a file and a function, both of which must be there."""
    match = re.search(r'handler\s*=\s*"([^"]+)"', MAIN)
    assert match, "the function resource declares no handler"

    module_name, function_name = match.group(1).rsplit(".", 1)
    assert (AUTHORIZERS / "function" / f"{module_name}.py").is_file()
    assert callable(getattr(authz, function_name, None))


def _declared_exclusions():
    block = repofiles._balanced_block(
        MAIN, MAIN.index('data "archive_file" "scope_enforcer"'))
    match = re.search(r"excludes\s*=\s*\[(.*?)\]", block, re.S)
    return re.findall(r'"([^"]+)"', match.group(1)) if match else []


def _packaged_files():
    """What the archive would actually contain.

    Modelled on how the provider builds it: an exclusion is compared against the
    path relative to the source directory with string equality -- no globbing --
    and a DIRECTORY that matches is skipped whole, which is why naming one
    covers everything beneath it.
    """
    match = re.search(r'source_dir\s*=\s*"\$\{path\.module\}/([^"]+)"', MAIN)
    assert match, "the archive does not package a directory of the module"

    source = AUTHORIZERS / match.group(1)
    excluded = set(_declared_exclusions())
    packaged = []
    for entry in sorted(source.rglob("*")):
        relative = entry.relative_to(source)
        if any(str(pathlib.PurePath(*relative.parts[:depth])) in excluded
               for depth in range(1, len(relative.parts) + 1)):
            continue
        if entry.is_file():
            packaged.append(str(relative))
    return packaged


def test_the_package_holds_only_the_function():
    """What is uploaded is the handler and nothing else.

    An editor backup, a stray helper or a compiled module would all go up
    beside it, and a package that differs from the tree is a package nobody has
    read. Checked against what the archive would contain rather than against
    what git tracks, because git is not what decides.
    """
    assert _packaged_files() == ["handler.py"], (
        f"the package would also carry {_packaged_files()}"
    )


def test_compiled_bytecode_is_excluded_from_the_package():
    """The gap .gitignore does not close.

    The archive is built from the directory on disk, so ignoring __pycache__
    keeps it out of review and not out of the upload. Anything that imports the
    handler locally -- a syntax check, this suite -- leaves one behind, and the
    next apply from that checkout ships it.

    The exclusion is checked for being an exact name because this provider
    compares exclusions with string equality and does no globbing: "*.pyc" is
    accepted, matches nothing, and reads as though it were applied.
    """
    excluded = _declared_exclusions()
    assert excluded, "the archive declares no exclusions, so a __pycache__ would ship"
    assert "__pycache__" in excluded
    assert not any("*" in entry or "?" in entry for entry in excluded), (
        f"a glob matches nothing in this provider: {excluded}"
    )


def test_running_this_suite_leaves_nothing_in_the_packaged_directory():
    """Belt to the exclusion's braces, and the reason the exclusion is needed.

    Bytecode writing is turned off for the suite, so a checkout used for both
    testing and applying stays clean even before the exclusion is consulted.
    """
    assert sys.dont_write_bytecode, "conftest must disable bytecode for this to hold"
    stray = [p.name for p in (AUTHORIZERS / "function").rglob("*")
             if p.is_file() and p.suffix != ".py"]
    assert stray == [], f"the suite left {stray} where the package is built"


def test_the_build_directory_is_never_committed():
    """The zip is written into the module at plan time.

    It is a build artefact with a content hash in it, so committing one puts a
    file in the tree that changes whenever anything else does.
    """
    match = re.search(r'output_path\s*=\s*"\$\{path\.module\}/([^/]+)/', MAIN)
    assert match, "the archive output path was restructured"

    ignored = (ROOT / ".gitignore").read_text()
    assert match.group(1) in ignored, (
        f"{match.group(1)}/ is written at plan time and is not in .gitignore"
    )
    assert not list(AUTHORIZERS.glob(f"{match.group(1)}/*"))


def test_the_function_parses_under_the_runtime_it_is_deployed_on():
    match = re.search(r'runtime\s*=\s*"python(\d+)\.(\d+)"', MAIN)
    assert match, "the function declares no Python runtime"

    major, minor = int(match.group(1)), int(match.group(2))
    assert (major, minor) >= (3, 9), "the function uses syntax below 3.9 nowhere"
    compile(HANDLER.read_text(), str(HANDLER), "exec")


def test_the_function_has_no_dependencies_to_install():
    """The package is the source directory and nothing else.

    There is no build step and no layer, so an import of anything outside the
    standard library would fail at the first invocation -- in production, on a
    request, as a 500.
    """
    tree = ast.parse(HANDLER.read_text())
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            imported.add(node.module.split(".")[0])

    stdlib = getattr(__import__("sys"), "stdlib_module_names", None)
    if stdlib is None:  # Python 3.9
        stdlib = {"base64", "binascii", "hashlib", "hmac", "json", "logging",
                  "os", "time", "urllib", "typing", "__future__"}
    assert imported <= set(stdlib), f"not in the standard library: {sorted(imported - set(stdlib))}"


# ---------------------------------------------------------------------------
# The answer shape and the authorizer that expects it
# ---------------------------------------------------------------------------


def test_a_bundled_authorizer_is_required_to_expect_the_simple_form():
    """The function answers in the simple form only.

    An authorizer told to expect an IAM policy reads that answer as malformed
    and fails the request, which looks like the function erroring rather than
    like two settings disagreeing -- so the pairing is refused at plan time.
    """
    block = repofiles.variable_block(VARIABLES, "lambda_authorizers")
    assert re.search(
        r'v\.payload_format_version == "2\.0" && v\.enable_simple_responses'
        r'\s+if v\.scope_enforcement != null', block)


def test_the_event_fields_the_function_reads_are_payload_format_2_fields():
    """``identitySource`` and ``routeKey`` exist in the 2.0 event and not in 1.0.

    The pairing above is what guarantees a bundled function is only ever sent
    the shape it reads.
    """
    source = HANDLER.read_text()
    for field in ("identitySource", "routeKey", "requestContext"):
        assert f'"{field}"' in source


def test_the_authorizer_timeout_is_spent_before_the_integration(varfile=VARIABLES):
    """An authorizer runs inside the request.

    Its timeout is time the caller waits before the integration is even
    reached, so the cap has to sit below the gateway's own ceiling rather than
    at it.
    """
    block = repofiles.variable_block(varfile, "lambda_authorizers")
    match = re.search(r"v\.scope_enforcement\.timeout_seconds >= 1 && "
                      r"v\.scope_enforcement\.timeout_seconds <= (\d+)", block)
    assert match, "the authorizer timeout bound was renamed"
    assert int(match.group(1)) < 30


# ---------------------------------------------------------------------------
# Repository conventions
# ---------------------------------------------------------------------------


def test_every_terraform_directory_declares_its_providers():
    """A module that uses a provider it does not declare inherits the root's.

    That works until the module is called from somewhere else, where it
    silently resolves to whatever that root happens to pin.
    """
    for directory in repofiles.terraform_directories():
        versions = directory / "versions.tf"
        assert versions.is_file(), f"{directory.name} has no versions.tf"
        assert "required_providers" in versions.read_text()


def test_no_committed_file_carries_a_real_looking_account_id():
    """Examples use the documentation account id and nothing else."""
    # The documentation account ids, which is the set this repository's own
    # pre-commit scan treats as placeholders. A narrower list here would reject
    # a README that is correct.
    allowed = {
        "123456789012", "111111111111", "222222222222", "333333333333",
        "444444444444", "555555555555", "999999999999", "000000000000",
        "987654321098", "012345678901",
    }
    for path in ROOT.rglob("*"):
        if not path.is_file() or ".git/" in str(path) or path.suffix == ".pyc":
            continue
        for found in re.findall(r"(?<![0-9])[0-9]{12}(?![0-9])", path.read_text(errors="ignore")):
            assert found in allowed, f"{path.relative_to(ROOT)} carries {found}"
