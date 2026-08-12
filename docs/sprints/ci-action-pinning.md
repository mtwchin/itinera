# Sprint P6 — Immutable CI action references

**Started:** July 16, 2026  
**Status:** Locally validated; awaiting intentional review and integration  
**Scope:** Pin every third-party GitHub Action used by the CI workflow to an
immutable commit ID.

## Control

Major-version action tags are mutable references. CI now pins each external
action to the commit currently resolved from its intended major tag, while
retaining a comment for maintainers:

| Action | Intended version | Pinned commit |
|---|---:|---|
| `actions/checkout` | v4 | `34e114876b0b11c390a56381ad16ebd13914f8d5` |
| `actions/setup-node` | v4 | `49933ea5288caeca8642d1e84afbd3f7d6820020` |
| `actions/setup-python` | v5 | `a26af69be951a213d495a4c3e4e4022e16d87065` |
| `actions/upload-artifact` | v4 | `ea165f8d65b6e75b540449e92b4886f43607fa02` |

The values were resolved with `git ls-remote --refs` from the corresponding
official GitHub repositories. A deployment-config test rejects a return to
mutable major-tag references.

Full backend lint and test evidence is green: Ruff passed and all **247
runnable tests passed** (16 real-infrastructure tests skipped locally); Docker
Compose configuration and OpenAPI drift checks also passed.

## Remaining scope

Action pinning removes one runner-execution risk. Dependency and container
vulnerability scanning, SBOM publication, secret scanning, base-image digest
pinning, and an automated action-update review process remain NXT-021 work.
