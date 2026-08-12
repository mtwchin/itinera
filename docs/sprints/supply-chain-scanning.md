# P16 — Blocking supply-chain scans

**Status:** Locally configuration-validated; awaiting CI execution and
intentional review/integration.

## Outcome

CI has a least-privilege `supply-chain-scan` job using the immutable Trivy
action revision `a9c7b0f06e461e9d4b4d1711f154ee024b8d7ab8` (v0.36.0).

The job fails on high- or critical-severity findings that have a fix for:

- filesystem dependency vulnerabilities and committed secrets;
- the locally built production runtime image.

It builds `itinera:ci` from the digest-pinned Dockerfile with `--pull=false`,
so the image scan evaluates the same declared base image and runtime
requirements as deployment.

The same image produces a CycloneDX JSON SBOM artifact retained for 90 days.
This gives release reviewers an immutable dependency inventory for every CI
run without granting the job write access to the repository or dependency graph.

## Boundary

`ignore-unfixed: true` prevents blocking on findings with no published remediated
version; this is not a risk acceptance. The first CI execution must review the
report and create an owner/expiry for every accepted exception.

A transitive dependency hash lock, vulnerability-report retention beyond the
CI artifact, and a scheduled scan/update process remain NXT-021 work.
