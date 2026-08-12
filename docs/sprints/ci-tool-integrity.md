# Sprint P5 — CI build-tool integrity

**Started:** July 16, 2026  
**Status:** Locally validated; awaiting intentional review and integration  
**Scope:** Integrity verification for the XcodeGen archive executed by iOS CI.

## Problem and control

The iOS job pinned an XcodeGen release version but downloaded and executed its
archive without checking its bytes. A mutable or compromised release artifact
could therefore alter the generated Xcode project or the CI runner.

CI now pins the expected SHA-256 for XcodeGen 2.45.4 and verifies the downloaded
archive before extraction. A mismatch produces a clear workflow error and exits
before any archive contents are executed. The expected digest is:

```
090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef
```

## Evidence and boundary

- Downloaded the release archive from the configured GitHub URL and verified
  the digest locally with `shasum -a 256`; `unzip -tq` also passed.
- Added a deployment-config test that confirms CI verifies before `ditto`
  extraction.
- Full backend lint and test evidence is green: Ruff passed and all **246
  runnable tests passed** (16 real-infrastructure tests skipped locally);
  Docker Compose configuration and OpenAPI drift checks also passed.
- This controls the XcodeGen binary only. Pinning GitHub Actions by immutable
  commit, dependency/SBOM scanning, secret scanning, container scanning, and
  base-image pinning remain NXT-021 work.
