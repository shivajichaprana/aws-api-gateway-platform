"""What the authorizer decides, and why.

The shape of this file follows one rule: every check that can fail open is
tested in BOTH directions. A test that only proves a valid token is accepted
reports exactly what it would report if the function returned ``True`` without
reading anything.
"""

from __future__ import annotations

import json
import time
import urllib.request

import pytest

from conftest import AUDIENCE, ISSUER, authz, event
from jwks import JwksTransport, SigningKey, b64url

NOW = 1_800_000_000


def claims(**overrides):
    base = {
        "iss": ISSUER,
        "aud": AUDIENCE[0],
        "sub": "user-1",
        "exp": NOW + 600,
        "iat": NOW - 10,
        "scope": "orders:read orders:write",
    }
    base.update(overrides)
    return {key: value for key, value in base.items() if value is not None}


@pytest.fixture(autouse=True)
def frozen_clock(monkeypatch):
    monkeypatch.setattr(time, "time", lambda: float(NOW))


# ---------------------------------------------------------------------------
# The happy path, so the refusals below mean something
# ---------------------------------------------------------------------------


def test_a_valid_token_is_authorized(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    result = authz.handler(event(signing_key.token(claims())))

    assert result["isAuthorized"] is True
    assert result["context"]["sub"] == "user-1"
    assert result["context"]["scope"] == "orders:read orders:write"
    assert result["context"]["requiredScope"] == "orders:read"
    assert result["context"]["issuer"] == ISSUER


def test_context_values_are_all_strings(configure, jwks, signing_key):
    """Integration context values arrive as strings whatever was put in them."""
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    result = authz.handler(event(signing_key.token(claims(sub=12345))))

    assert result["isAuthorized"] is True
    assert all(isinstance(value, str) for value in result["context"].values())
    assert result["context"]["sub"] == "12345"


def test_the_answer_is_the_simple_form(configure, jwks, signing_key):
    """The authorizer is declared with simple responses, so it answers that way.

    An IAM policy document here would be read as a malformed response and fail
    the request -- which looks like the function erroring, not like a shape
    disagreement between two files.
    """
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    granted = authz.handler(event(signing_key.token(claims())))
    refused = authz.handler(event("not-a-token"))

    for result in (granted, refused):
        assert set(result) == {"isAuthorized", "context"}
        assert isinstance(result["isAuthorized"], bool)
        assert "policyDocument" not in result
        assert "principalId" not in result


# ---------------------------------------------------------------------------
# Signature verification
# ---------------------------------------------------------------------------


def test_a_token_signed_by_another_key_is_refused(configure, jwks):
    """The published key is what decides, not the token's own claim to be valid."""
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    impostor = SigningKey("primary")  # same kid, different key

    result = authz.handler(event(impostor.token(claims())))
    assert result["isAuthorized"] is False


def test_an_unsigned_token_is_refused(configure, jwks, signing_key):
    """``alg: none`` is the oldest way in, and it is refused by the key.

    The algorithm comes from the published key, so a token naming a different
    one is refused before its signature is even looked at.
    """
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims(), alg="RS256")
    header, payload, _ = token.split(".")
    unsigned = f"{b64url(json.dumps({'alg': 'none', 'kid': 'primary'}).encode())}.{payload}."

    assert authz.handler(event(unsigned))["isAuthorized"] is False


def test_an_hmac_token_keyed_on_the_public_key_is_refused(configure, jwks, signing_key):
    """The other half of the algorithm confusion: symmetric, keyed on a public value.

    An RSA public key is public, so an HS256 token signed with it verifies for
    anybody who can read the key set. Symmetric algorithms are not in the
    accepted set at all.
    """
    import hashlib
    import hmac as hmac_module

    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    header = b64url(json.dumps({"alg": "HS256", "kid": "primary"}).encode())
    payload = b64url(json.dumps(claims()).encode())
    secret = json.dumps(signing_key.jwk()["n"]).encode()
    signature = hmac_module.new(secret, f"{header}.{payload}".encode(), hashlib.sha256)
    forged = f"{header}.{payload}.{b64url(signature.digest())}"

    assert authz.handler(event(forged))["isAuthorized"] is False


def test_a_tampered_payload_is_refused(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims(scope="orders:read"))
    header, _, signature = token.split(".")
    escalated = b64url(json.dumps(claims(scope="orders:admin")).encode())

    assert authz.handler(event(f"{header}.{escalated}.{signature}"))["isAuthorized"] is False


def test_a_token_naming_an_unpublished_key_is_refused(configure, jwks, signing_key):
    """Selection is by key id, never by trying each key in turn.

    Trying every key means one the issuer has rotated out keeps working while it
    is still published, which is the opposite of what rotating it was for.
    """
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    result = authz.handler(event(signing_key.token(claims(), kid="retired")))

    assert result["isAuthorized"] is False
    assert jwks.calls >= 1, "an unknown key id must force one refresh"


def test_an_unknown_key_id_forces_exactly_one_refresh(configure, monkeypatch, signing_key):
    """One refresh, so a rotation a minute ago succeeds -- and only one."""
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    transport = JwksTransport(ISSUER, [signing_key])
    monkeypatch.setattr(urllib.request, "urlopen", transport)

    assert authz.handler(event(signing_key.token(claims())))["isAuthorized"] is True
    before = transport.calls

    authz.handler(event(signing_key.token(claims(), kid="rotated-in")))
    assert transport.calls == before + 1


def test_a_key_set_that_cannot_be_read_denies(configure, monkeypatch, signing_key):
    """An unreachable issuer denies, and it does not crash on the way.

    A socket error escaping as an unhandled exception is reported as an
    authorizer that broke rather than an issuer that could not be reached. Both
    deny; only one says where to look.
    """
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    transport = JwksTransport(ISSUER, [signing_key])
    transport.fail_with = OSError("connection reset")
    monkeypatch.setattr(urllib.request, "urlopen", transport)

    result = authz.handler(event(signing_key.token(claims())))
    assert result["isAuthorized"] is False
    assert "key set" in result["context"]["reason"]


def test_an_http_issuer_is_never_fetched(configure, signing_key):
    """Plain http would put the key set on the wire for anyone to replace."""
    configure(ISSUER="http://issuer.example.invalid/tenant",
              REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    # The network guard is still armed: reaching out at all fails this test.
    assert authz.handler(event(signing_key.token(claims())))["isAuthorized"] is False


def test_a_key_without_an_algorithm_is_assumed_rs256(configure, monkeypatch):
    """The common real shape: a key set that publishes no ``alg``."""
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    key = SigningKey("primary", alg=None)
    monkeypatch.setattr(urllib.request, "urlopen", JwksTransport(ISSUER, [key]))

    assert authz.handler(event(key.token(claims(), alg="RS256")))["isAuthorized"] is True
    # And a genuine RS384 token is refused rather than allowed to revise the
    # assumption -- the token does not get to say which algorithm applies.
    assert authz.handler(event(key.token(claims(), alg="RS384")))["isAuthorized"] is False


def test_a_malformed_token_denies_rather_than_raising(configure, jwks):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    for bad in ("", "one-part", "two.parts", "a.b.c", "....", "%%%.%%%.%%%"):
        assert authz.handler(event(bad))["isAuthorized"] is False


# ---------------------------------------------------------------------------
# Claims
# ---------------------------------------------------------------------------


def test_an_expired_token_is_refused(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims(exp=NOW - 3600))

    assert authz.handler(event(token))["isAuthorized"] is False


def test_a_token_with_no_expiry_is_refused(configure, jwks, signing_key):
    """The one a present-only check treats as having nothing to object to.

    A token with no ``exp`` never expires. A verifier that checks the claim only
    when it is there accepts the most dangerous token it can be handed.
    """
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    result = authz.handler(event(signing_key.token(claims(exp=None))))

    assert result["isAuthorized"] is False
    assert "expiry" in result["context"]["reason"]


def test_a_non_numeric_expiry_is_refused(configure, jwks, signing_key):
    """A string expiry is not a late expiry, and a boolean is not a number."""
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    for value in ("9999999999", True, [NOW + 600], None):
        token = signing_key.token(claims(exp=value))
        assert authz.handler(event(token))["isAuthorized"] is False


def test_skew_covers_a_clock_that_disagrees_and_no_more(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]},
              CLOCK_SKEW_SECONDS="60")

    just_inside = signing_key.token(claims(exp=NOW - 30))
    well_outside = signing_key.token(claims(exp=NOW - 120))

    assert authz.handler(event(just_inside))["isAuthorized"] is True
    assert authz.handler(event(well_outside))["isAuthorized"] is False


def test_a_token_not_yet_valid_is_refused(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]},
              CLOCK_SKEW_SECONDS="0")
    token = signing_key.token(claims(nbf=NOW + 300))

    assert authz.handler(event(token))["isAuthorized"] is False


def test_a_token_from_another_issuer_is_refused(configure, jwks, signing_key):
    """Signed by the right key, issued by someone else: still refused."""
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims(iss="https://issuer.example.invalid/other"))

    assert authz.handler(event(token))["isAuthorized"] is False


def test_a_token_for_another_audience_is_refused(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims(aud="somebody-elses-api"))

    assert authz.handler(event(token))["isAuthorized"] is False


def test_an_access_token_names_its_audience_in_client_id(configure, jwks, signing_key):
    """An access token frequently carries no ``aud`` at all.

    A Cognito access token names the app client in ``client_id``, and API
    Gateway's own JWT authorizer accepts either. Insisting on ``aud`` refuses
    every access token the same issuer minted.
    """
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims(aud=None, client_id=AUDIENCE[0]))

    assert authz.handler(event(token))["isAuthorized"] is True


def test_a_token_naming_no_audience_at_all_is_refused(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims(aud=None))

    assert authz.handler(event(token))["isAuthorized"] is False


def test_one_matching_audience_among_several_is_enough(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims(aud=["another-api", AUDIENCE[0]]))

    assert authz.handler(event(token))["isAuthorized"] is True


# ---------------------------------------------------------------------------
# Scopes -- the reason this function exists
# ---------------------------------------------------------------------------


def test_every_required_scope_is_required(configure, jwks, signing_key):
    """All of them, not any of them.

    API Gateway's own route-level scopes grant a request carrying ANY ONE of the
    listed values. That is the behaviour this function exists to replace, so a
    token holding one of two required scopes must be refused here.
    """
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read", "orders:audit"]})
    token = signing_key.token(claims(scope="orders:read"))

    result = authz.handler(event(token))
    assert result["isAuthorized"] is False
    assert "orders:audit" in result["context"]["reason"]


def test_holding_all_required_scopes_is_enough(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read", "orders:audit"]})
    token = signing_key.token(claims(scope="orders:audit extra orders:read"))

    assert authz.handler(event(token))["isAuthorized"] is True


def test_scopes_are_read_from_either_claim(configure, jwks, signing_key):
    """``scope`` is a space-delimited string; ``scp`` is a list. Issuers differ."""
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})

    as_string = signing_key.token(claims(scope="orders:read"))
    as_list = signing_key.token(claims(scope=None, scp=["orders:read"]))
    as_scp_string = signing_key.token(claims(scope=None, scp="orders:read"))

    for token in (as_string, as_list, as_scp_string):
        assert authz.handler(event(token))["isAuthorized"] is True


def test_scopes_are_decided_per_route(configure, jwks, signing_key):
    """The whole point of keying on the route.

    A token good for reading must not be good for writing simply because the
    same authorizer decided its first request.
    """
    configure(REQUIRED_SCOPES={
        "GET /orders": ["orders:read"],
        "POST /orders": ["orders:write"],
    })
    reader = signing_key.token(claims(scope="orders:read"))

    assert authz.handler(event(reader, "GET /orders"))["isAuthorized"] is True
    assert authz.handler(event(reader, "POST /orders"))["isAuthorized"] is False


def test_an_unlisted_route_is_denied_by_default(configure, jwks, signing_key):
    """A route added without a scope entry fails shut.

    The mistake then shows up as a route that does not work, which somebody
    fixes, rather than as a route that works for everyone, which nobody sees.
    """
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims())

    assert authz.handler(event(token, "DELETE /orders/{orderId}"))["isAuthorized"] is False


def test_an_unlisted_route_can_be_allowed_deliberately(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]},
              UNLISTED_ROUTE_ACTION="allow")
    token = signing_key.token(claims())

    result = authz.handler(event(token, "DELETE /orders/{orderId}"))
    assert result["isAuthorized"] is True
    assert result["context"]["requiredScope"] == ""


def test_the_default_entry_covers_routes_with_no_entry_of_their_own(
        configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"$default": ["orders:read"]})
    token = signing_key.token(claims(scope="orders:read"))

    assert authz.handler(event(token, "PATCH /anything"))["isAuthorized"] is True
    assert authz.handler(
        event(signing_key.token(claims(scope="something:else")), "PATCH /anything")
    )["isAuthorized"] is False


def test_an_exact_route_entry_beats_the_default(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={
        "$default": ["orders:read"],
        "POST /orders": ["orders:write"],
    })
    token = signing_key.token(claims(scope="orders:read"))

    assert authz.handler(event(token, "GET /orders"))["isAuthorized"] is True
    assert authz.handler(event(token, "POST /orders"))["isAuthorized"] is False


# ---------------------------------------------------------------------------
# The event
# ---------------------------------------------------------------------------


def test_the_token_is_read_from_the_identity_source(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims())

    assert authz.handler(
        event(identity_source=[f"Bearer {token}"])
    )["isAuthorized"] is True


def test_the_authorization_header_is_a_fallback(configure, jwks, signing_key):
    """Read case-insensitively, because a header name is not case sensitive."""
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims())

    for name in ("Authorization", "authorization", "AUTHORIZATION"):
        payload = event(headers={name: f"Bearer {token}"})
        assert authz.handler(payload)["isAuthorized"] is True


def test_the_bearer_prefix_is_optional_and_case_insensitive(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims())

    for value in (token, f"Bearer {token}", f"bearer {token}", f"  Bearer  {token} "):
        assert authz.handler(event(identity_source=[value]))["isAuthorized"] is True


def test_a_request_with_no_token_is_refused(configure, jwks):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})

    for payload in ({}, {"routeKey": "GET /orders"},
                    event(identity_source=[]),
                    event(identity_source=["", "   "]),
                    event(headers={"authorization": ""})):
        assert authz.handler(payload)["isAuthorized"] is False


def test_an_event_naming_no_route_is_refused(configure, jwks, signing_key):
    """Without a route there is no entry to look up, so there is nothing to allow."""
    configure(REQUIRED_SCOPES={"$default": ["orders:read"]})
    token = signing_key.token(claims())

    assert authz.handler({"identitySource": [token]})["isAuthorized"] is False


def test_the_route_key_is_read_from_the_request_context_too(configure, jwks, signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})
    token = signing_key.token(claims())

    payload = {"identitySource": [token],
               "requestContext": {"routeKey": "GET /orders"}}
    assert authz.handler(payload)["isAuthorized"] is True


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def test_an_unconfigured_authorizer_denies_everything(monkeypatch, jwks, signing_key):
    """Missing configuration must not be a way through.

    This is the one that decides what a deployment mistake costs: an authorizer
    that treats an absent issuer as nothing to check would grant every request
    on the API it was added to protect.
    """
    token = signing_key.token(claims())
    assert authz.handler(event(token))["isAuthorized"] is False

    monkeypatch.setenv("ISSUER", ISSUER)
    assert authz.handler(event(token))["isAuthorized"] is False  # no audience

    monkeypatch.delenv("ISSUER")
    monkeypatch.setenv("AUDIENCE", json.dumps(AUDIENCE))
    assert authz.handler(event(token))["isAuthorized"] is False  # no issuer


def test_unparseable_configuration_falls_back_rather_than_crashing(configure, jwks,
                                                                   signing_key):
    """A malformed scope map leaves every route unlisted, and unlisted denies."""
    configure(REQUIRED_SCOPES="{not json")
    assert authz.handler(event(signing_key.token(claims())))["isAuthorized"] is False


def test_a_non_numeric_cache_setting_falls_back_to_the_default(configure, jwks,
                                                               signing_key):
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]},
              JWKS_CACHE_SECONDS="ten minutes")

    assert authz.handler(event(signing_key.token(claims())))["isAuthorized"] is True


def test_an_unexpected_failure_denies(configure, jwks, signing_key, monkeypatch):
    """Whatever breaks, the answer is no.

    An authorizer that fails open is worse than one that is absent, because the
    API it guards looks guarded.
    """
    configure(REQUIRED_SCOPES={"GET /orders": ["orders:read"]})

    def explode(*_args, **_kwargs):
        raise RuntimeError("something nobody anticipated")

    monkeypatch.setattr(authz, "token_scopes", explode)
    result = authz.handler(event(signing_key.token(claims())))

    assert result["isAuthorized"] is False
    assert "RuntimeError" in result["context"]["reason"]
