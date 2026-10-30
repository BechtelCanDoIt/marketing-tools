# ADR-027: One Docker context per component, shared packages built inside the image

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** plan M8 (top risk: clean-checkout builds); amends the build notes of ADR-020 and ADR-021

## Context

`amplify-api` and `amplify-jobs` depend on `wso2/amplify_common` and `wso2/amplify_domain` with `repository = "local"` (ADR-020/021). Two things had to hold for Docker, Compose and Choreo builds:

1. **Clean checkout.** Nothing may come from a developer's `~/.ballerina/repositories/local`. The Dockerfiles already pack and push both libraries to the build stage's *own* local repository before `bal build`; M8 verified it with `docker build --no-cache` of every image (and `docker compose build --no-cache`) on an empty cache.
2. **Choreo descriptor location.** For Dockerfile-built components Choreo reads the descriptor from `<docker context>/.choreo/component.yaml` ([source configurations](https://wso2.com/choreo/docs/develop-components/manage-component-source-configurations/)). With one shared context (`projects/marketing-tools/apps/amplify`) for api and jobs, both components would read the *same* `component.yaml`, so jobs would get the api's endpoint, schema and env (and the reverse).

Options for (2):

- **a. Unique ancestor contexts.** api builds from `projects/marketing-tools/apps/amplify`, jobs from `projects/marketing-tools/apps/amplify/apps` (flattened 2026-10-20: jobs now shares the `apps/amplify` context; descriptor kept at `amplify-jobs/.choreo/component.yaml`); both contain the shared packages. No tooling, works today.
- **b. Ballerina Central** (an org on Central, `repository` dropped). Each component builds from its own folder. Needs a Central org, publish credentials in CI and a release per shared change.
- **c. Vendored copies or a CI-assembled build branch.** Duplicated sources or a second branch to keep in step.

Ballerina 2201.13 has no path/workspace dependency that would let a component folder reach its siblings either.

## Decision

Option a, with every component on its own context:

| Component | Docker context | Dockerfile | Choreo descriptor |
|---|---|---|---|
| amplify-api | `projects/marketing-tools/apps/amplify` | `amplify-api/Dockerfile` | `projects/marketing-tools/apps/amplify/.choreo/component.yaml` |
| amplify-jobs | `projects/marketing-tools/apps/amplify` | `amplify-jobs/Dockerfile` | `projects/marketing-tools/apps/amplify/.choreo/component.yaml` |
| amplify-database | `amplify-database` | its folder | its folder `.choreo/` |
| amplify-scheduler | `amplify-scheduler` | its folder | its folder `.choreo/` |
| mock-linkedin (dev) | `projects/marketing-tools/apps/amplify/linkedin/apps/mock_linkedin` | its folder | its folder `.choreo/` |

- `schemaFilePath` is relative to the context (`amplify-api/openapi.yaml`, `amplify-jobs/openapi.yaml`).
- `compose.yaml` uses the same contexts, so a local build is the Choreo build.
- `workload.yaml` (OpenChoreo) stays in each component folder; `scripts/check-descriptors.sh` maps each descriptor to its workload, Dockerfile and Compose service and fails on drift.
- Each context has a `.dockerignore` (`target/`, `Config.toml`, `.git`).

## Consequences

- Clean checkout to image with no local setup, verified for all six images; `make up` + `scripts/e2e-local.sh` run on images built with `--no-cache`.
- The api component's Choreo build is triggered by any change under `projects/marketing-tools/apps/amplify`; jobs by any change under `apps/`. Acceptable for two services.
- There is no third unique ancestor: **a third consumer of the shared packages (or a repo move, D12) is the trigger to switch to option b.** The switch changes only `Ballerina.toml` (`repository` dropped), the Dockerfiles (no pack/push) and the contexts back to component folders.
- Reviewers: a `.choreo/` folder at `projects/marketing-tools/apps/amplify` and at `apps/` is deliberate, not stray.
