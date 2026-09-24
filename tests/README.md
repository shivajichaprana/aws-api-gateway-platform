# Tests

Offline. No credentials, no network, nothing created. Everything here runs from
a clean checkout with `pip install -r tests/requirements.txt`.

```
pytest tests -q            # the suite
python tests/lint_openapi.py   # the document gate on its own
```

## What this covers that nothing else does

Terraform validates that a configuration is well formed. API Gateway validates
that an OpenAPI document has the right shape. Python validates nothing until
the function runs, which for an authorizer is inside somebody's request. The
gaps between those three are where this suite lives.

| File | What it is for |
|---|---|
| `test_authorizer.py` | What the authorizer decides, and why. Every check that can fail open is exercised in both directions. |
| `test_crypto.py` | The bundled verifier, against signatures made by a different implementation and forgeries that implementation will not produce. |
| `test_contracts.py` | What two files have to agree about and nothing enforces — chiefly the environment Terraform writes against the environment the function reads. |
| `test_openapi.py` | The document that *is* the API: the things API Gateway imports cleanly and then does not do. |
| `lint_openapi.py` | The same document rules as a standalone gate, so they keep running when a test runner is not configured. |

## Conventions

**Both directions, always.** A test proving a valid token is accepted reports
exactly what it would report if the function returned `True` without reading
anything. Every refusal has a matching acceptance and every acceptance a
matching refusal.

**The doubles are strict.** The key-set transport refuses a URL it was not told
to serve, and an unexpected network call fails the test that made it. A test
that reached the real internet would either pass slowly or fail for a reason
that has nothing to do with the code, and both read as noise.

**The readers raise.** Nothing in `repofiles.py` falls back to an empty result.
A reader that quietly returns nothing turns a test into an assertion about an
empty set, which passes and proves nothing — so a rename fails here, loudly,
rather than leaving a suite that is exercising no code at all.

**The function is loaded by path.** A Lambda bundle is flat, so the module is
`handler` — a name several functions share — and an ordinary import could
resolve to a different one entirely.

**The rules are shared.** `test_openapi.py` and `lint_openapi.py` both call
`openapi_rules.py`, so the suite and the gate cannot disagree about the same
file, and `test_openapi.py` shows each rule rejecting a document that breaks it.

## Known limits

- The Terraform readers are narrow parsers over the files they name, not a HCL
  implementation. They recognise the shapes this repository uses and raise on
  anything else.
- Nothing here plans or applies. Whether a configuration is accepted by the
  provider is the pipeline's job; whether it describes a working API is this
  suite's.
- `test_crypto.py` proves the verifier, not the transport it fetches keys over.
