"""Real RSA keys, real signatures, and a key set that is served rather than faked.

The bundled verifier is the one part of this module that cannot be reviewed by
reading it and believing the comments: if it is wrong, every other check here
is decoration on an authorizer that accepts forgeries. So the signatures it is
asked to verify are produced by a DIFFERENT implementation -- ``cryptography``,
which is not the code under test -- and the forgeries are ones that library will
not produce.

The transport is deliberately strict. It refuses a URL it was not told to
serve, so a test that reaches for the wrong issuer fails loudly instead of
quietly answering with the only key set in the fixture.
"""

from __future__ import annotations

import base64
import json
from typing import Any, Dict, Iterable, List, Optional

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

HASHES = {
    "RS256": hashes.SHA256,
    "RS384": hashes.SHA384,
    "RS512": hashes.SHA512,
}


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def b64url_json(value: Any) -> str:
    return b64url(json.dumps(value, separators=(",", ":")).encode("utf-8"))


def b64url_uint(value: int) -> str:
    length = (value.bit_length() + 7) // 8 or 1
    return b64url(value.to_bytes(length, "big"))


class SigningKey:
    """One RSA key, with the JWKS entry that publishes it."""

    def __init__(self, kid: str, bits: int = 2048, public_exponent: int = 65537,
                 alg: Optional[str] = "RS256") -> None:
        self.kid = kid
        self.alg = alg
        self.private = rsa.generate_private_key(
            public_exponent=public_exponent, key_size=bits
        )

    def jwk(self) -> Dict[str, Any]:
        numbers = self.private.public_key().public_numbers()
        entry = {
            "kty": "RSA",
            "kid": self.kid,
            "use": "sig",
            "n": b64url_uint(numbers.n),
            "e": b64url_uint(numbers.e),
        }
        # A key set in the wild may or may not name the algorithm. Both shapes
        # are exercised, because the handler assumes RS256 when it is absent and
        # that assumption is load-bearing.
        if self.alg is not None:
            entry["alg"] = self.alg
        return entry

    def sign(self, message: bytes, alg: str = "RS256") -> bytes:
        return self.private.sign(message, padding.PKCS1v15(), HASHES[alg]())

    def token(self, claims: Dict[str, Any], *, alg: str = "RS256",
              kid: Optional[str] = None, header_extra: Optional[Dict[str, Any]] = None,
              signature: Optional[bytes] = None) -> str:
        header: Dict[str, Any] = {"alg": alg, "typ": "JWT"}
        header["kid"] = self.kid if kid is None else kid
        if header_extra:
            header.update(header_extra)

        encoded_header = b64url_json(header)
        encoded_claims = b64url_json(claims)
        signing_input = f"{encoded_header}.{encoded_claims}".encode("ascii")

        raw = self.sign(signing_input, alg) if signature is None else signature
        return f"{encoded_header}.{encoded_claims}.{b64url(raw)}"


class JwksTransport:
    """Serve a key set at exactly one URL, and refuse every other request.

    Refusing rather than returning an empty document is the point: an authorizer
    asked for the wrong issuer must fail a test, not fall through to whatever
    the fixture happens to hold.
    """

    def __init__(self, issuer: str, keys: Iterable[SigningKey]) -> None:
        self.url = issuer.rstrip("/") + "/.well-known/jwks.json"
        self.keys: List[SigningKey] = list(keys)
        self.calls = 0
        self.fail_with: Optional[BaseException] = None
        self.body: Optional[bytes] = None

    def document(self) -> Dict[str, Any]:
        return {"keys": [key.jwk() for key in self.keys]}

    def __call__(self, request: Any, timeout: Optional[float] = None) -> Any:
        url = getattr(request, "full_url", request)
        if url != self.url:
            raise AssertionError(
                f"the authorizer asked for {url!r}, but this fixture serves {self.url!r}"
            )
        self.calls += 1
        if self.fail_with is not None:
            raise self.fail_with
        payload = self.body
        if payload is None:
            payload = json.dumps(self.document()).encode("utf-8")
        return _Response(payload)


class _Response:
    def __init__(self, payload: bytes) -> None:
        self._payload = payload

    def read(self) -> bytes:
        return self._payload

    def __enter__(self) -> "_Response":
        return self

    def __exit__(self, *_: Any) -> bool:
        return False
