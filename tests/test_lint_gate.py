"""The standalone gate, shown failing.

A gate that has only ever been observed passing is indistinguishable from one
that checks nothing, and this gate runs in the pipeline on its own, where
nothing else would notice.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

import pytest

from repofiles import DOCUMENT, ROOT

GATE = ROOT / "tests" / "lint_openapi.py"


def run(root) -> subprocess.CompletedProcess:
    """Run the gate that lives under ``root``.

    The gate resolves the repository from its OWN location rather than from the
    working directory, so a fixture that copies it and then runs the original
    checks the real tree and reports a pass whatever it did to the copy.
    """
    gate = pathlib.Path(root) / "tests" / "lint_openapi.py"
    assert gate.is_file(), f"no gate at {gate}"
    return subprocess.run([sys.executable, str(gate)], cwd=root,
                          capture_output=True, text=True)


def _stage(tmp_path):
    """Copy the gate and its rules into an empty tree."""
    (tmp_path / "tests").mkdir()
    for name in ("lint_openapi.py", "openapi_rules.py"):
        (tmp_path / "tests" / name).write_bytes((ROOT / "tests" / name).read_bytes())
    (tmp_path / "openapi").mkdir()
    return tmp_path


def test_the_gate_passes_on_this_repository():
    result = run(ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "0 problem(s)" in result.stdout


def test_the_gate_names_the_documents_it_checked():
    """So a run that checked less than expected is visible in the log."""
    result = run(ROOT)
    assert DOCUMENT.name in result.stdout


@pytest.mark.parametrize("break_it,expected", [
    ("httpMethod: POST", "invokes its integration"),
    ('$ref: "#/components/schemas/Order"', "resolves to nothing"),
])
def test_the_gate_fails_on_a_broken_document(tmp_path, break_it, expected):
    """A real document, broken one way, checked by the real gate."""
    _stage(tmp_path)

    source = DOCUMENT.read_text()
    assert source.count(break_it) >= 1, "the mutation anchor is not in the document"
    if break_it == "httpMethod: POST":
        broken = source.replace(break_it, "httpMethod: GET", 1)
    else:
        broken = source.replace(break_it, '$ref: "#/components/schemas/Gone"', 1)
    assert broken != source, "the mutation changed nothing"
    (tmp_path / "openapi" / DOCUMENT.name).write_text(broken)

    result = run(tmp_path)
    assert result.returncode == 1
    assert expected in result.stdout


def test_a_run_that_finds_no_documents_fails(tmp_path):
    """Exiting zero here would report a green gate for a checkout with nothing
    in it, which is the shape of every silently disabled check."""
    _stage(tmp_path)

    result = run(tmp_path)
    assert result.returncode == 1
    assert "nothing was checked" in result.stdout
