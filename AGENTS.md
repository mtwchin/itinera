# Itinera development workflow

Use this workflow for every development session in this repository.

- Inspect `git status` before editing and preserve unrelated user changes.
- Never develop directly on `main`. Create a focused feature or fix branch; Codex branches use the `codex/` prefix.
- Keep each branch reviewable: one coherent concern, additive migrations, explicit API-contract changes, and no drive-by refactors.
- Treat privacy, authentication, ownership, accessibility, and failure states as product requirements rather than follow-up work.
- Add or update automated tests with behavior changes. Regenerate committed generated artifacts such as `api/openapi.json` in the same branch.
- Before handoff, run the relevant backend lint/tests and iOS generation/build/tests. Report any check that could not run and why.
- Do not commit secrets, local credentials, build products, simulator data, or editor/worktree metadata.
- Make intentional commits only after reviewing the diff and verification results. Push or open a pull request only when explicitly requested.
