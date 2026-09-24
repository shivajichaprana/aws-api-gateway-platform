"""The verifier, proved against an implementation that is not it.

Everything else in this suite rests on the assumption that a signature the
function accepts is a signature the issuer made. That assumption cannot be
checked by reading the code and believing the comments, so it is checked
against ``cryptography`` -- real keys, real signatures -- and against forged
blocks that library will not produce.
"""

from __future__ import annotations

import hashlib

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from conftest import authz

DIGESTS = {"sha256": hashes.SHA256, "sha384": hashes.SHA384, "sha512": hashes.SHA512}

# Two key sizes and two public exponents. The small exponent is the one that
# matters: e=3 is where a verifier that scans for the padding separator instead
# of rebuilding it becomes forgeable.
KEY_SHAPES = [(2048, 65537), (2048, 3), (3072, 65537)]


@pytest.fixture(scope="module")
def keys():
    return {
        shape: rsa.generate_private_key(public_exponent=shape[1], key_size=shape[0])
        for shape in KEY_SHAPES
    }


def _numbers(key):
    public = key.public_key().public_numbers()
    return public.n, public.e


@pytest.mark.parametrize("shape", KEY_SHAPES)
@pytest.mark.parametrize("hash_name", sorted(DIGESTS))
def test_a_real_signature_verifies(keys, shape, hash_name):
    key = keys[shape]
    message = b"the signing input of a token that was actually issued"
    signature = key.sign(message, padding.PKCS1v15(), DIGESTS[hash_name]())
    modulus, exponent = _numbers(key)

    assert authz.rsa_pkcs1_v15_verify(
        modulus, exponent, message, signature, hash_name
    ) is True


@pytest.mark.parametrize("shape", KEY_SHAPES)
def test_a_signature_of_a_different_message_is_refused(keys, shape):
    key = keys[shape]
    signature = key.sign(b"one message", padding.PKCS1v15(), hashes.SHA256())
    modulus, exponent = _numbers(key)

    assert authz.rsa_pkcs1_v15_verify(
        modulus, exponent, b"another message", signature, "sha256"
    ) is False


def test_a_signature_is_tied_to_the_hash_it_was_made_with(keys):
    """The DigestInfo prefix is what ties them.

    Without it a SHA-256 signature would verify against a SHA-512 digest of
    different content, which is a signature that says nothing about what was
    signed.
    """
    key = keys[(2048, 65537)]
    modulus, exponent = _numbers(key)
    message = b"signing input"
    signature = key.sign(message, padding.PKCS1v15(), hashes.SHA256())

    assert authz.rsa_pkcs1_v15_verify(modulus, exponent, message, signature,
                                      "sha256") is True
    for other in ("sha384", "sha512"):
        assert authz.rsa_pkcs1_v15_verify(modulus, exponent, message, signature,
                                          other) is False


@pytest.mark.parametrize("shape", KEY_SHAPES)
def test_a_signature_of_the_wrong_length_is_refused(keys, shape):
    key = keys[shape]
    modulus, exponent = _numbers(key)
    message = b"signing input"
    signature = key.sign(message, padding.PKCS1v15(), hashes.SHA256())

    for mangled in (signature[:-1], signature[1:], b"\x00" + signature, b"", signature * 2):
        assert authz.rsa_pkcs1_v15_verify(
            modulus, exponent, message, mangled, "sha256"
        ) is False


def test_a_signature_at_or_above_the_modulus_is_refused(keys):
    """RFC 8017 requires the signature to be less than the modulus.

    Written the obvious way this check SKIPS rather than passes, because s + n
    usually does not fit in k bytes and the oversized value is rejected for its
    length instead -- proving nothing about the comparison. So a signature is
    searched for where it does fit, and not finding one fails the test rather
    than quietly passing it.
    """
    key = keys[(2048, 65537)]
    modulus, exponent = _numbers(key)
    key_bytes = (modulus.bit_length() + 7) // 8
    ceiling = 1 << (8 * key_bytes)

    for attempt in range(200):
        message = f"signing input {attempt}".encode()
        raw = key.sign(message, padding.PKCS1v15(), hashes.SHA256())
        value = int.from_bytes(raw, "big")
        if value + modulus < ceiling:
            wrapped = (value + modulus).to_bytes(key_bytes, "big")
            assert authz.rsa_pkcs1_v15_verify(
                modulus, exponent, message, raw, "sha256"
            ) is True
            assert authz.rsa_pkcs1_v15_verify(
                modulus, exponent, message, wrapped, "sha256"
            ) is False
            return

    pytest.fail("no signature small enough to test the modulus bound was found")


def test_a_block_with_shortened_padding_is_refused(keys):
    """The Bleichenbacher shape, built with the private key rather than guessed.

    A verifier that finds the 0x00 separator and reads whatever follows accepts
    a block whose padding run has been cut short and the remainder filled with
    anything -- which with a small public exponent is forgeable without the
    private key at all. The block below is malformed in exactly that way and
    then signed properly, so the only thing that can reject it is rebuilding the
    padding and comparing it in full.
    """
    key = keys[(2048, 3)]
    modulus, exponent = _numbers(key)
    private = key.private_numbers().d
    key_bytes = (modulus.bit_length() + 7) // 8

    message = b"signing input"
    digest_info = authz._DIGEST_INFO["sha256"] + hashlib.sha256(message).digest()

    # Two bytes of padding instead of the full run, then the DigestInfo, then
    # filler where the verifier is not supposed to be looking.
    filler = key_bytes - len(digest_info) - 5
    forged_block = (
        b"\x00\x01" + b"\xff" * 2 + b"\x00" + digest_info + b"\x41" * filler
    )
    assert len(forged_block) == key_bytes

    signature = pow(int.from_bytes(forged_block, "big"), private, modulus)
    raw = signature.to_bytes(key_bytes, "big")

    assert authz.rsa_pkcs1_v15_verify(
        modulus, exponent, message, raw, "sha256"
    ) is False


def test_a_block_whose_padding_is_not_a_run_of_ff_is_refused(keys):
    """The other half of rebuilding the padding, and the one easily missed.

    A verifier that checks only the first two bytes and the last few accepts
    any filler in between, so the whole padding run stops carrying information.
    The block below begins correctly and ends with exactly the right
    DigestInfo, and is still not a PKCS#1 v1.5 signature: the run has to be
    0xff throughout and has to end at a 0x00 separator.
    """
    key = keys[(2048, 3)]
    modulus, exponent = _numbers(key)
    private = key.private_numbers().d
    key_bytes = (modulus.bit_length() + 7) // 8

    message = b"signing input"
    digest_info = authz._DIGEST_INFO["sha256"] + hashlib.sha256(message).digest()

    forged_block = b"\x00\x01" + b"\x00" * (key_bytes - len(digest_info) - 2) + digest_info
    assert len(forged_block) == key_bytes
    assert forged_block.startswith(b"\x00\x01") and forged_block.endswith(digest_info)

    raw = pow(int.from_bytes(forged_block, "big"), private, modulus).to_bytes(key_bytes, "big")
    assert authz.rsa_pkcs1_v15_verify(
        modulus, exponent, message, raw, "sha256"
    ) is False


def test_a_block_with_the_wrong_leading_bytes_is_refused(keys):
    key = keys[(2048, 65537)]
    modulus, exponent = _numbers(key)
    private = key.private_numbers().d
    key_bytes = (modulus.bit_length() + 7) // 8

    message = b"signing input"
    digest_info = authz._DIGEST_INFO["sha256"] + hashlib.sha256(message).digest()
    run = b"\xff" * (key_bytes - len(digest_info) - 3)

    for leader in (b"\x00\x02", b"\x01\x01", b"\x00\x00"):
        block = leader + run + b"\x00" + digest_info
        raw = pow(int.from_bytes(block, "big"), private, modulus).to_bytes(key_bytes, "big")
        assert authz.rsa_pkcs1_v15_verify(
            modulus, exponent, message, raw, "sha256"
        ) is False


@pytest.mark.parametrize("filler", [b"\x00", b"\xff", b"\x01"])
def test_a_degenerate_signature_is_refused(keys, filler):
    key = keys[(2048, 65537)]
    modulus, exponent = _numbers(key)
    key_bytes = (modulus.bit_length() + 7) // 8

    assert authz.rsa_pkcs1_v15_verify(
        modulus, exponent, b"signing input", filler * key_bytes, "sha256"
    ) is False


def test_only_rsa_algorithms_are_accepted():
    """The accepted set and the digest table describe the same thing.

    A hash named in one and missing from the other is either an algorithm that
    is accepted and then crashes on a lookup, or one that is carried and never
    reachable.
    """
    assert set(authz._ALGORITHMS) == {"RS256", "RS384", "RS512"}
    assert set(authz._ALGORITHMS.values()) == set(authz._DIGEST_INFO)
    assert not any(name.startswith(("HS", "ES", "PS", "none"))
                   for name in authz._ALGORITHMS)


def test_the_digest_info_prefixes_are_the_ones_rfc_8017_defines():
    """Checked against the hash itself rather than against a second copy.

    Each prefix is a DER header whose last byte is the digest length, so an
    entry transcribed for the wrong hash disagrees with the digest it names.
    """
    for hash_name, prefix in authz._DIGEST_INFO.items():
        assert prefix[-1] == hashlib.new(hash_name).digest_size
        assert prefix[0] == 0x30, "a DigestInfo is a DER SEQUENCE"
