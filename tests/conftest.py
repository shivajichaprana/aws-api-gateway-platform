"""Fixtures. Nothing here reaches the network, and nothing leaks between tests.

The function is loaded BY PATH. A Lambda bundle is flat, so the module is
simply ``handler`` -- a name several functions in this estate share -- and an
ordinary import would resolve to whichever one a test runner happened to find
first. Loading it explicitly also means a rename fails here, loudly, rather
than leaving a suite that passes because it is exercising nothing.
"""

from __future__ import annotations

import importlib.util
import sys
import urllib.request

from typing import Any, Dict, List

import pytest

from jwks import JwksTransport, SigningKey
from repofiles import HANDLER

# Set before the function is loaded below. It is loaded from the directory the
# deployment package is built from, so importing it normally would leave a
# __pycache__ exactly where the archive is assembled. The module excludes that
# directory too; this keeps a checkout used for both testing and applying clean
# in the first place.
sys.dont_write_bytecode = True

ISSUER = "https://issuer.example.invalid/tenant"
AUDIENCE = ["orders-api"]


def _load_handler():
    spec = importlib.util.spec_from_file_location("bundled_authorizer", HANDLER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"the authorizer function is not at {HANDLER}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["bundled_authorizer"] = module
    spec.loader.exec_module(module)
    return module


authz = _load_handler()


@pytest.fixture(autouse=True)
def isolated_environment(monkeypatch):
    """Every test starts with no authorizer configuration and an empty cache.

    The key cache is module-level state that outlives an invocation on purpose
    -- that is what it is for -- so leaving it populated would let one test's
    key set decide another test's result.
    """
    for name in (
        "ISSUER", "AUDIENCE", "REQUIRED_SCOPES", "UNLISTED_ROUTE_ACTION",
        "JWKS_CACHE_SECONDS", "CLOCK_SKEW_SECONDS", "LOG_LEVEL",
    ):
        monkeypatch.delenv(name, raising=False)
    authz._JWKS_CACHE.clear()
    yield
    authz._JWKS_CACHE.clear()


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    """Refuse any request a test did not arrange.

    A test that reaches the real internet would either pass slowly or fail for
    a reason that has nothing to do with the code, and both read as noise.
    """

    def refuse(*_args: Any, **_kwargs: Any):
        raise AssertionError("this test made an unexpected network call")

    monkeypatch.setattr(urllib.request, "urlopen", refuse)


@pytest.fixture
def signing_key() -> SigningKey:
    return SigningKey("primary")


@pytest.fixture
def jwks(monkeypatch, signing_key) -> JwksTransport:
    transport = JwksTransport(ISSUER, [signing_key])
    monkeypatch.setattr(urllib.request, "urlopen", transport)
    return transport


@pytest.fixture
def configure(monkeypatch):
    """Set the authorizer's configuration the way Terraform does.

    Values are written in the same encodings the module uses -- JSON for the
    audience and the scope map, decimal strings for the numbers -- so a test
    exercises the parsing as well as the decision.
    """
    import json

    def apply(**overrides: Any) -> None:
        settings: Dict[str, Any] = {
            "ISSUER": ISSUER,
            "AUDIENCE": json.dumps(AUDIENCE),
        }
        settings.update(overrides)
        for name, value in settings.items():
            if value is None:
                monkeypatch.delenv(name, raising=False)
            elif isinstance(value, str):
                monkeypatch.setenv(name, value)
            else:
                monkeypatch.setenv(name, json.dumps(value))

    return apply


def event(token: str = None, route_key: str = "GET /orders",
          identity_source: List[str] = None,
          headers: Dict[str, str] = None) -> Dict[str, Any]:
    """An HTTP API request-authorizer event, payload format 2.0."""
    payload: Dict[str, Any] = {"version": "2.0", "type": "REQUEST",
                               "routeKey": route_key}
    if identity_source is not None:
        payload["identitySource"] = identity_source
    elif token is not None:
        payload["identitySource"] = [f"Bearer {token}"]
    if headers is not None:
        payload["headers"] = headers
    return payload
