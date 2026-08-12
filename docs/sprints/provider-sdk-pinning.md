# P15 — Direct provider SDK pinning

**Status:** Locally validated; awaiting intentional review and integration.

## Outcome

The direct Anthropic and Google GenAI runtime dependencies are now exact-pinned
in `requirements.txt`:

| Package | Pin |
|---|---:|
| `anthropic` | `0.116.0` |
| `google-genai` | `2.11.0` |

Previously, compatible-version ranges allowed the same source revision to
resolve a newer provider client at build time. A deployment-config test now
rejects those ranges, keeping the direct-client contract reviewable.

## Evidence

- The exact pair was installed in the local Python 3.11 environment.
- Both provider modules import successfully.
- `google.genai.types.GenerateContentConfig(max_output_tokens=8000)` accepts
  the editor's bounded-output configuration.

## Remaining scope

This controls direct runtime SDK drift only. NXT-021 still needs a reproducible
transitive lock or hash policy, SBOM publication, secret/dependency/container
scans, and an intentional dependency-update workflow.

## Container base image

Both Docker build stages now use the immutable multi-architecture digest
`python:3.12-slim@sha256:57cd7c3a7a273101a6485ba99423ee568157882804b1124b4dd04266317710de`.
The digest was read from Docker Hub's registry manifest for the intended tag,
and a deployment-config test requires both stages to retain it. Digest updates
are an intentional dependency review, not an automatic rebuild side effect.

PostgreSQL, Redis, and Jaeger service images are also digest-pinned in local
Compose; PostgreSQL and Redis use the same pinned digests in CI's integration
services. The one local `itinera:ci` image tag is built in the job immediately
before it is scanned, so it is not an external mutable reference.
