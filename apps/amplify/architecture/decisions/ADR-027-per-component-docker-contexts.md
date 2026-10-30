# ADR-027: One Docker context per component, shared packages built inside the image

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** plan M8 (top risk: clean-checkout builds); amends the build notes of ADR-020 and ADR-021

## Context

`amplify-api` and `amplify-jobs` depend on `wso2/amplify_common` and `wso2/amplify_domain` with `repository = "local"` (ADR-020/021). Two things had to hold for Docker, Compose and Choreo builds:

1. **Clean checkout.** Nothing may come from a developer's `~/.ballerina/repositories/local`. The Dockerfiles already pack and push both libraries to the build stage's *own* local repository before `bal build`; M8 verified it with `docker build --no-cache` of every image (and `docker compose build --no-cache`) on an empty cache.
2. **Choreo descriptor location.** For Dockerfile-built components Choreo reads the descriptor from `<docker context>/.choreo/component.yaml` ([source configurations](https://wso2.com/choreo/docs/develop-components/manage-component-source-configurations/)). With one shared context (`apps/amplify`) for api and jobs, both components would read the *same* `component.yaml`, so jobs would get the api's endpoint, schema and env (and the reverse).

Options for (2):

- **a. Unique ancestor contexts.** Each component builds from a context that is a *different* ancestor folder, and both folders contain the shared packages, so Choreo reads a different `<context>/.choreo/component.yaml` for each. No tooling, works today. (On 2026-10-20 the contexts were flattened to one, `apps/amplify`, for both api and jobs; that removes the unique ancestor the option depends on — see the amendment below.)
- **b. Ballerina Central** (an org on Central, `repository` dropped). Each component builds from its own folder. Needs a Central org, publish credentials in CI and a release per shared change.
- **c. Vendored copies or a CI-assembled build branch.** Duplicated sources or a second branch to keep in step.

Ballerina 2201.13 has no path/workspace dependency that would let a component folder reach its siblings either.

## Decision

Option a, with every component on its own context:

| Component | Docker context | Dockerfile | Descriptor of record | Choreo reads |
|---|---|---|---|---|
| amplify-api | `apps/amplify` | `amplify-api/Dockerfile` | `apps/amplify/.choreo/component.yaml` | `apps/amplify/.choreo/component.yaml` |
| amplify-jobs | `apps/amplify` | `amplify-jobs/Dockerfile` | `amplify-jobs/.choreo/component.yaml` | `apps/amplify/.choreo/component.yaml` — the api's, which is the defect the amendment below records |
| amplify-database | `amplify-database` | its folder | its folder `.choreo/` | its folder `.choreo/` |
| amplify-scheduler | `amplify-scheduler` | its folder | its folder `.choreo/` | its folder `.choreo/` |
| mock-linkedin (dev) | `apps/amplify/linkedin/apps/mock_linkedin` | its folder | its folder `.choreo/` | its folder `.choreo/` |

- `schemaFilePath` is relative to the context (`amplify-api/openapi.yaml`, `amplify-jobs/openapi.yaml`).
- `compose.yaml` uses the same contexts, so a local build is the Choreo build.
- `workload.yaml` (OpenChoreo) stays in each component folder; `scripts/check-descriptors.sh` maps each descriptor to its workload, Dockerfile and Compose service and fails on drift.
- Each context has a `.dockerignore` (`target/`, `Config.toml`, `.git`).

## Consequences

- Clean checkout to image with no local setup, verified for all six images; `make up` + `scripts/e2e-local.sh` run on images built with `--no-cache`.
- The api component's Choreo build is triggered by any change under `apps/amplify`; jobs by any change under `apps/amplify` too, since the flattening below. Acceptable for two services.
- There is no third unique ancestor: **a third consumer of the shared packages (or a repo move, D12) is the trigger to switch to option b.** The switch changes only `Ballerina.toml` (`repository` dropped), the Dockerfiles (no pack/push) and the contexts back to component folders.
- Reviewers: the `.choreo/` folder at `apps/amplify` and the one in each component folder are deliberate, not stray.

## Amendment (2026-10-30)

The 2026-10-20 flattening took away the condition this ADR relies on, and the decision table above did not say so.

- **What the flattening changed.** api and jobs now both build from the `apps/amplify` context. Neither has a unique ancestor any more, so there is only one `apps/amplify/.choreo/component.yaml` for Choreo to read, and it is the **api's** (endpoint `amplify-api`, port 9090, the api's `schemaFilePath` and env). `amplify-jobs/.choreo/component.yaml` (port 9091, the jobs env, never published) is still what `amplify-jobs/workload.yaml` and `scripts/check-descriptors.sh` pair with, but **Choreo does not read it while the contexts are shared**. That is exactly the failure option (a) exists to prevent, and the "Docker context: apps/amplify … so every component has its own context" comment in both descriptors is false until it is fixed.
- **Consequence.** Amplify Jobs cannot be created as a Choreo Dockerfile component from this layout; it would take the api's endpoint. The api component is unaffected.
- **The options are the ones above.** Restore a second unique ancestor context for jobs (a), move the shared packages to Ballerina Central (b), or assemble a vendor/CI build branch (c). None is a doc change, so this ADR records the gap rather than picking one: the arrangement and the Jobs deployment route (OpenChoreo's `amplify-jobs/workload.yaml` is correct as it stands) are tracked in the Amplify Jobs review thread on the jobs slice, and the choice gets its own ADR when it is made.
- **Descriptor hygiene meanwhile.** Keep `amplify-jobs/.choreo/component.yaml` in step with its `workload.yaml` — `check-descriptors.sh` is still the gate that catches drift in the env names and ports, and it is what tells us the two descriptors are not interchangeable.
