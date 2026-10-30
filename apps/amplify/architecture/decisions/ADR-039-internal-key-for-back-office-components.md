# ADR-039: A shared internal key protects amplify-jobs

- **Status:** Accepted
- **Date:** 2026-10-30
- **Source:** Security review, "back-office components have no authentication"; refines ADR-003, ADR-026

## Context

amplify-jobs runs the strongest operations Amplify has (`POST /runs`, `/maintenance/partitions`, `/maintenance/rebuild-recognition`)
and had no authentication: Choreo Project visibility was the only control. The scheduler (the pinned `akorn/scheduler`
image, ADR-026) cannot authenticate its own callers at all.

## Decision

1. **A shared secret header.** Every call to amplify-jobs except `GET /health` and `GET /ready` must carry
   `X-Amplify-Internal-Key`. Jobs compares it in constant time and answers 401 otherwise, logging the route and whether a key
   was sent, never the key.
2. **Fail closed.** Jobs does not start without `internalApiKey` of at least 32 characters. amplify-api does not start without it
   when `jobsUrl` or `schedulerUrl` is set.
3. **Who sends it.** amplify-api on its "Save & Share Now" trigger, and the scheduler: amplify-api sets the header on each job it
   registers (`scheduler_sync.bal`), so a manual edit in the scheduler UI that drops the header is overwritten by the next reconcile.
4. **One secret per environment**, the same value on both components (`INTERNALAPIKEY` in Choreo secrets; `AMPLIFY_INTERNAL_API_KEY`
   locally, filled by `make env`). Rotation is a config change on both, then a scheduler sync.

## Consequences

- A pod in the project that does not hold the key can no longer start a run, a rebuild or partition maintenance.
- **Residual risk:** the scheduler's own API still has no authentication (the image has none), and the key now also sits in the
  scheduler's own database as a job header. Anyone who can reach the scheduler can read it and change jobs. Keep the scheduler behind
  a network policy that admits amplify-api only; that is a Platform action, listed in the security actions file.
- OAuth client credentials (a signed, expiring token) would be stronger but the scheduler cannot fetch tokens, so it would need a sidecar.

## Links

- Code: `amplify-jobs/auth.bal`, `amplify-api/outbound.bal` (`internalApiKey`), `amplify-api/scheduler_sync.bal`
