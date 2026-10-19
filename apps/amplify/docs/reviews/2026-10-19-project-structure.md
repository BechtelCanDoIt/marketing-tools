# Project structure review: Amplify in marketing-tools

Date: 2026-10-19 · Method: WSO2 Digital project-structure conventions · Scope: `apps/amplify` after the move into marketing-tools (ADR-033), and the workspace layout.

**Overall:** conforms on the things that matter for review and operation: every deployable has a `CLAUDE.md`, a committed `Dependencies.toml` and `observabilityIncluded = true`; schema changes are tracked as dated files in `docs/migrations/`; the repo has its README, LICENSE and issue/PR templates at the root. The deviations below are deliberate or low-cost.

| # | Convention | Status | Severity | Note / action |
|---|---|---|---|---|
| 1 | README with folder tree and app descriptions | **Fixed** | — | marketing-tools' README had one line; it now lists `amplify`, `conference` and `registrant` with a tree. `apps/amplify/README.md` already had its own layout. |
| 2 | `CLAUDE.md` per service | Partial | Low | The five Amplify packages have one. The local-only `chat-stub`, `people-stub` and `mock_linkedin` don't; they're small and documented in `README.md` and `docs/HowToTestLocally/TestAmplify.md` (workspace). Add if they grow. |
| 3 | `observabilityIncluded = true` | Met for deployables | — | Off only in `chat-stub` and `people-stub`, which never deploy. |
| 4 | `Cloud.toml` for Choreo | Deviation (by design) | — | Amplify builds with the Choreo **Dockerfile** preset (plan D11, ADR-027), not the Ballerina preset, so `Cloud.toml` doesn't apply; the descriptors are `.choreo/component.yaml` + `workload.yaml`. |
| 5 | `.gitsecret/` for credentials | Deviation (by design) | Low | Amplify commits no credentials at all: Choreo secrets in the cloud, a generated and git-ignored `local/.env` locally. Nothing to encrypt. |
| 6 | Repo taxonomy (`digiops-<domain>` for a domain suite) | Deviation | Low | marketing-tools is an existing WSO2 repo for marketing apps, so Amplify joins it instead of a new `digiops-marketing` (ADR-033). Revisit if marketing apps move to a digiops repo. |
| 7 | `apps/<app>/{webapp,bff}`; services as `entity-service/`, `operations/<task>-service/` | Deviation | Low | Amplify keeps its own `apps/` inside `apps/amplify` (so paths read `apps/amplify/apps/amplify-api`), and its services are named by role (api, jobs, scheduler, database) rather than `entity-service`/`operations`. Renaming would change every Docker context and Choreo path (ADR-027) for no runtime gain; not worth it before the pilot. |
| 8 | Dated migration notes in `docs/migrations/` | Met | — | `2026-10-17-v012-…`, `2026-10-17-v013-…`. |
| 9 | Workspace layout (`projects/`, `projects/research/`) | Not covered by the conventions | — | The workspace is a planning repo with code in submodules; its layout is documented in the root `README.md` and `CLAUDE.md`. |
