"""Request authorizer for an HTTP API: verifies a JWT and enforces scopes.

Answers in the simple format -- ``{"isAuthorized": bool, "context": {...}}`` --
which an HTTP API accepts when the authorizer is configured with payload format
2.0 and simple responses enabled.

Three things here are deliberate and are the reason this is not a thin wrapper
around a decode call.

Signature verification is done, not skipped. Decoding a JWT is not verifying
one: the payload of an unverified token is whatever the caller typed, so an
authorizer that reads claims without checking the signature accepts a token
anybody can write. Verification is RSASSA-PKCS1-v1_5 against the issuer's
published keys, implemented on the standard library so the function ships with
no dependencies to resolve, pin or patch.

The algorithm is taken from the KEY, never from the token. A verifier that
dispatches on the token's own ``alg`` header can be handed ``none`` (no
signature to check) or ``HS256`` (symmetric, keyed on a value the attacker
already has, because an RSA public key is public). Both produce a token that
verifies. The key says which algorithm it is for, and a token claiming any
other is refused before anything else is read.

Scopes are required, not offered. API Gateway's own route-level
``authorization_scopes`` grants a request that carries ANY ONE of the listed
scopes; a route listing three is satisfied by a token holding one. This
function requires ALL of the scopes configured for the route, which is what a
list of scopes usually means to whoever wrote it.

Every failure denies. An unreachable key set, an unparseable token, an
unexpected exception: all of them answer no. The reason is logged; the caller
is told nothing beyond the refusal, because an authorizer that explains which
check failed is a tool for finding the check that does not.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import logging
import os
import time
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

LOGGER = logging.getLogger()
LOGGER.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

# RFC 8017 DigestInfo prefixes. The padded block a PKCS#1 v1.5 signature
# decrypts to ends with one of these followed by the digest itself, so the
# prefix is what ties a signature to the hash it was made with -- without it a
# SHA-256 signature would verify against a SHA-512 digest of different content.
_DIGEST_INFO = {
    "sha256": binascii.unhexlify("3031300d060960864801650304020105000420"),
    "sha384": binascii.unhexlify("3041300d060960864801650304020205000430"),
    "sha512": binascii.unhexlify("3051300d060960864801650304020305000440"),
}

# The only algorithms accepted, and the hash each one names. Symmetric
# algorithms are absent on purpose: this function holds a public key, and a
# public key used as an HMAC secret is a secret everybody has.
_ALGORITHMS = {"RS256": "sha256", "RS384": "sha384", "RS512": "sha512"}

_JWKS_CACHE: Dict[str, Tuple[float, Dict[str, Dict[str, Any]]]] = {}


class Denied(Exception):
    """A request that will not be authorized, carrying the reason for the log."""


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def _env(name: str, default: str = "") -> str:
    value = os.environ.get(name, default)
    return value.strip() if value else default


def _int_env(name: str, default: int) -> int:
    raw = _env(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        LOGGER.warning("%s is not an integer, using %s", name, default)
        return default


def _json_env(name: str, default: Any) -> Any:
    raw = _env(name)
    if not raw:
        return default
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        LOGGER.warning("%s is not valid JSON, using the default", name)
        return default


# ---------------------------------------------------------------------------
# base64url and JWKS
# ---------------------------------------------------------------------------


def _b64url_decode(value: str) -> bytes:
    """Decode base64url. JWT strips the padding; adding it back is on us."""
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


def _b64url_int(value: str) -> int:
    return int.from_bytes(_b64url_decode(value), "big")


def _jwks_url(issuer: str) -> str:
    return issuer.rstrip("/") + "/.well-known/jwks.json"


def _fetch_jwks(issuer: str, timeout: float = 3.0) -> Dict[str, Dict[str, Any]]:
    url = _jwks_url(issuer)
    if not url.startswith("https://"):
        raise Denied("issuer is not an https URL")

    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # nosec B310
            document = json.loads(response.read().decode("utf-8"))
    # OSError rather than URLError: urllib raises URLError for most failures,
    # but a socket-level error surfaces bare, and one that escapes here is
    # reported as an authorizer that crashed rather than an issuer that could
    # not be reached. Both still deny; only one says where to look.
    except (OSError, TimeoutError, ValueError) as error:
        raise Denied(f"could not read the key set: {error}") from error

    keys = {}
    for key in document.get("keys", []):
        kid = key.get("kid")
        if kid and key.get("kty") == "RSA":
            keys[kid] = key
    if not keys:
        raise Denied("the key set contains no usable RSA keys")
    return keys


def _get_key(issuer: str, kid: str, cache_seconds: int) -> Dict[str, Any]:
    """Return the signing key named by ``kid``, refreshing the cache once if it
    is unknown.

    The key is selected by ``kid`` and never by position. Trying every key in
    turn means a key the issuer has rotated out keeps working for as long as it
    is still published, which is the opposite of what rotating it was for. The
    single forced refresh is what makes a rotation that happened a minute ago
    succeed rather than fail for the length of the cache.
    """
    cached = _JWKS_CACHE.get(issuer)
    if cached and cached[0] > time.time() and kid in cached[1]:
        return cached[1][kid]

    keys = _fetch_jwks(issuer)
    _JWKS_CACHE[issuer] = (time.time() + cache_seconds, keys)

    if kid not in keys:
        raise Denied("the token was signed with a key the issuer does not publish")
    return keys[kid]


# ---------------------------------------------------------------------------
# Signature verification
# ---------------------------------------------------------------------------


def rsa_pkcs1_v15_verify(
    modulus: int, exponent: int, message: bytes, signature: bytes, hash_name: str
) -> bool:
    """Verify an RSASSA-PKCS1-v1_5 signature (RFC 8017, section 8.2.2).

    The whole operation is a public-key exponentiation and a comparison against
    a block of a known shape, so it needs nothing but ``pow`` and ``hashlib``.
    The padding is rebuilt and compared in full rather than scanned for the
    separator: a verifier that searches for the 0x00 byte and reads whatever
    follows accepts signatures with a shortened padding run, which is the
    Bleichenbacher forgery that bites implementations using a small exponent.
    """
    key_bytes = (modulus.bit_length() + 7) // 8
    if len(signature) != key_bytes:
        return False

    signature_int = int.from_bytes(signature, "big")
    if signature_int >= modulus:
        return False

    encoded = pow(signature_int, exponent, modulus).to_bytes(key_bytes, "big")

    digest_info = _DIGEST_INFO[hash_name] + hashlib.new(hash_name, message).digest()
    if key_bytes < len(digest_info) + 11:
        return False

    expected = (
        b"\x00\x01"
        + b"\xff" * (key_bytes - len(digest_info) - 3)
        + b"\x00"
        + digest_info
    )
    return hmac.compare_digest(encoded, expected)


def _verify_signature(token: str, issuer: str, cache_seconds: int) -> Dict[str, Any]:
    parts = token.split(".")
    if len(parts) != 3:
        raise Denied("the token is not a three-part JWS")

    try:
        header = json.loads(_b64url_decode(parts[0]))
        claims = json.loads(_b64url_decode(parts[1]))
        signature = _b64url_decode(parts[2])
    except (binascii.Error, ValueError, UnicodeDecodeError) as error:
        raise Denied(f"the token could not be decoded: {error}") from error

    if not isinstance(header, dict) or not isinstance(claims, dict):
        raise Denied("the token header or payload is not an object")

    kid = header.get("kid")
    if not kid:
        raise Denied("the token header names no key")

    key = _get_key(issuer, kid, cache_seconds)

    # The key decides the algorithm. The token is only allowed to agree.
    key_algorithm = key.get("alg") or "RS256"
    if key_algorithm not in _ALGORITHMS:
        raise Denied(f"the signing key names an unsupported algorithm: {key_algorithm}")
    if header.get("alg") != key_algorithm:
        raise Denied("the token algorithm does not match the signing key")

    signing_input = f"{parts[0]}.{parts[1]}".encode("ascii")
    verified = rsa_pkcs1_v15_verify(
        _b64url_int(key["n"]),
        _b64url_int(key["e"]),
        signing_input,
        signature,
        _ALGORITHMS[key_algorithm],
    )
    if not verified:
        raise Denied("the token signature is not valid for the published key")
    return claims


# ---------------------------------------------------------------------------
# Claims
# ---------------------------------------------------------------------------


def _as_number(claims: Dict[str, Any], name: str) -> Optional[float]:
    value = claims.get(name)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _check_time_claims(claims: Dict[str, Any], skew: int, now: Optional[float] = None) -> None:
    """Check expiry and not-before.

    ``exp`` is required rather than checked when present. A token with no
    expiry never expires, and a verifier that only looks when the claim is there
    treats the most dangerous token it can be handed as the one with nothing to
    object to.
    """
    now = time.time() if now is None else now

    expires_at = _as_number(claims, "exp")
    if expires_at is None:
        raise Denied("the token carries no expiry")
    if now > expires_at + skew:
        raise Denied("the token has expired")

    not_before = _as_number(claims, "nbf")
    if not_before is not None and now + skew < not_before:
        raise Denied("the token is not valid yet")


def _check_audience(claims: Dict[str, Any], accepted: List[str]) -> None:
    """Match the audience, reading ``client_id`` when ``aud`` is absent.

    An OIDC id token carries ``aud``. An access token frequently does not: a
    Cognito access token names the app client in ``client_id`` and has no
    ``aud`` at all, and API Gateway's own JWT authorizer accepts either. A check
    that insists on ``aud`` refuses every access token the same issuer minted.
    """
    raw = claims.get("aud")
    if raw is None:
        raw = claims.get("client_id")

    if isinstance(raw, str):
        present = [raw]
    elif isinstance(raw, list):
        present = [item for item in raw if isinstance(item, str)]
    else:
        present = []

    if not present:
        raise Denied("the token names no audience")
    if not set(present) & set(accepted):
        raise Denied("the token was not issued for this API")


def token_scopes(claims: Dict[str, Any]) -> List[str]:
    """Read the granted scopes.

    ``scope`` is a single space-delimited string in OAuth 2.0; ``scp`` is a list
    in several issuers' access tokens. Both are read, because which one appears
    is a property of the issuer rather than of the caller.
    """
    scopes: List[str] = []

    raw = claims.get("scope")
    if isinstance(raw, str):
        scopes.extend(raw.split())
    elif isinstance(raw, list):
        scopes.extend(item for item in raw if isinstance(item, str))

    alternative = claims.get("scp")
    if isinstance(alternative, list):
        scopes.extend(item for item in alternative if isinstance(item, str))
    elif isinstance(alternative, str):
        scopes.extend(alternative.split())

    return sorted(set(scopes))


def check_scopes(
    route_key: str,
    granted: List[str],
    required_by_route: Dict[str, List[str]],
    unlisted_action: str,
) -> List[str]:
    """Require every scope the route asks for, and return the ones it asked for.

    A route with no entry is decided by ``unlisted_action``. Denying by default
    means a route added without a scope entry is refused rather than opened, so
    the mistake shows up as a route that does not work instead of as a route
    that works for everyone.
    """
    required = required_by_route.get(route_key)
    if required is None:
        required = required_by_route.get("$default")

    if required is None:
        if unlisted_action == "allow":
            return []
        raise Denied(f"no scopes are configured for route {route_key}")

    missing = sorted(set(required) - set(granted))
    if missing:
        raise Denied(f"the token is missing required scopes: {', '.join(missing)}")
    return sorted(set(required))


# ---------------------------------------------------------------------------
# Event
# ---------------------------------------------------------------------------


def extract_token(event: Dict[str, Any]) -> str:
    """Pull the bearer token out of the authorizer event.

    ``identitySource`` is what API Gateway extracted using the identity sources
    the authorizer declares, so it is read first; the header is a fallback for
    an event shape that does not carry it.
    """
    candidates: List[str] = []

    sources = event.get("identitySource")
    if isinstance(sources, list):
        candidates.extend(item for item in sources if isinstance(item, str))

    headers = event.get("headers")
    if isinstance(headers, dict):
        for name, value in headers.items():
            if isinstance(name, str) and name.lower() == "authorization" and isinstance(value, str):
                candidates.append(value)

    for candidate in candidates:
        value = candidate.strip()
        if not value:
            continue
        if value.lower().startswith("bearer "):
            value = value[7:].strip()
        if value:
            return value

    raise Denied("the request carries no token")


def _route_key(event: Dict[str, Any]) -> str:
    route_key = event.get("routeKey")
    if isinstance(route_key, str) and route_key:
        return route_key

    context = event.get("requestContext")
    if isinstance(context, dict) and isinstance(context.get("routeKey"), str):
        return context["routeKey"]

    raise Denied("the event names no route")


def _deny(reason: str) -> Dict[str, Any]:
    LOGGER.info("denied: %s", reason)
    return {"isAuthorized": False, "context": {"reason": reason}}


def handler(event: Dict[str, Any], context: Any = None) -> Dict[str, Any]:  # noqa: ARG001
    issuer = _env("ISSUER")
    audience = _json_env("AUDIENCE", [])
    required_by_route = _json_env("REQUIRED_SCOPES", {})
    unlisted_action = _env("UNLISTED_ROUTE_ACTION", "deny")
    cache_seconds = _int_env("JWKS_CACHE_SECONDS", 600)
    skew = _int_env("CLOCK_SKEW_SECONDS", 60)

    try:
        if not issuer or not audience:
            raise Denied("the authorizer is not configured with an issuer and an audience")

        route_key = _route_key(event)
        token = extract_token(event)
        claims = _verify_signature(token, issuer, cache_seconds)

        if claims.get("iss") != issuer:
            raise Denied("the token was issued by someone else")
        _check_time_claims(claims, skew)
        _check_audience(claims, list(audience))

        granted = token_scopes(claims)
        satisfied = check_scopes(route_key, granted, required_by_route, unlisted_action)
    except Denied as denial:
        return _deny(str(denial))
    except Exception as error:  # noqa: BLE001 - an authorizer never fails open
        LOGGER.exception("authorizer failed")
        return _deny(f"the authorizer could not decide: {type(error).__name__}")

    LOGGER.info("authorized route %s", route_key)
    return {
        "isAuthorized": True,
        # Context values reach the integration as strings, so they are made into
        # strings here rather than left for something else to stringify in a
        # shape nobody chose.
        "context": {
            "sub": str(claims.get("sub", "")),
            "scope": " ".join(granted),
            "requiredScope": " ".join(satisfied),
            "issuer": issuer,
        },
    }
