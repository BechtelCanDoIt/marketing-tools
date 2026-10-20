# Deep review: amplify-jobs, amplify-database, delivery/infra (2026-10-17)

Branch `rv-jobsdb` off `feat/phase1-build` @ `a603099`. Reviewer: Claude (agent), for Scott.

## Scope

- `amplify-jobs/**` (the Run, handlers, outbound, ports, maintenance endpoints, tests)
- `amplify-database/**` (V001–V011, S001–S004, migrate runner, checks, tests)
- `amplify-scheduler/**`, `apps/.choreo/**`, `.choreo/**`, `local/**` (chat-stub, dev-jwt, `.env.example`),
  `scripts/**`, `Makefile`, `compose.yaml`, every `Dockerfile`
- Runbooks `docs/runbooks/operations.md` and `resilience-targets.md` (repo root), only where these fixes change facts

Out of scope (handed off below): amplify-api, amplify-common, amplify-domain, projects/linkedin, architecture docs.

## Method

1. Read every file in scope, then the ADRs that govern it (003, 005, 020, 021, 024–029), the data model
   (grants table, partitions), the scheduler research note and the runbooks. Checklists applied: WSO2 Digital
   coding standards (Ballerina, SQL), engineering governance, integration boundary (idempotency, correlation,
   at-least-once), code-review.
2. Read the scheduler's source at the pinned tag (v1.7.8) for the `job_history` question (the
   `DELETE /jobs/{id}/history?before=` route and the table definition).
3. Baseline: unit tests with coverage in jobs, database, chat-stub; IT groups against a private
   `postgres:18` (`amplify-rv-jobsdb-pg`, 127.0.0.1:55434) and `mock_linkedin` on 19190/19191.
4. Fix loop: each real finding got a fix and a regression test that fails on `a603099` and passes after
   (verified by running the new tests against the original code / without V012 / without the retention SQL).
5. Second pass over the whole diff; rerun every suite; checks.

`scripts/it-scheduler.sh` was reviewed, not run: it runs the amplify-api `scheduler-it` group, whose test
module starts the api listener on 9090 (reserved on this machine).

## Findings

Severity: **Blocking** / **Should fix** / **Consider**. Line numbers are at `a603099`.

| ID | Sev | Where | Finding | Status |
| --- | --- | --- | --- | --- |
| J1 | Should fix | `amplify-jobs/service.bal:39-44` | No `GET /ready` (M10 gap): the platform and Compose could only see liveness. | **Fixed + test.** `/ready` = DB breaker not OPEN and `SELECT 1` answers; LinkedIn/Chat breakers and `runInProgress` reported, not fatal (mirrors the api, ADR-024/025); refreshes the breaker gauges (ADR-028). OpenAPI updated; Compose healthcheck now uses `/ready`. Tests: `ready_test.bal` (503 without DB + body, readiness gating). |
| J2 | Should fix | `amplify-jobs/run.bal:81-86` | A panic inside a run (index out of range, bad cast in a handler or repository) skipped `releaseFlag()` and the lock release: every later `POST /runs` answered 202 SKIPPED until the process restarted, and the session advisory lock stayed held. | **Fixed + test.** `trap` around `tryAcquire` and `execute`. `aPanicInsideARunReleasesTheFlagAndTheLock` (fails on `a603099`). |
| J3 | Should fix | `amplify-jobs/config.bal:28-31` | "`runMaxSeconds` must stay below `runLockLeaseSeconds`" was a comment only. A row started at the end of the budget plus its call (10 s LinkedIn, 10+1 s Chat) can outlive the lease; the next run then releases it as stale while it is still being handled, so a LinkedIn post can go out twice. | **Fixed + test.** `validateRunConfig` at module init (startup fails on bad tuning): positive sizes, `maxSeconds + longest call < lease`, sane backoff. Defaults pass (240 + 11 < 300). 4 tests in `ready_test.bal`. |
| J4 | Consider | `amplify-jobs/handlers.bal:211-213` | The LinkedIn ceiling was taken before the campaign read and the token decrypt, so a share that never reached LinkedIn used up the per-run/day budget and deferred a good share. | **Fixed + test.** Taken right before `publishShare`. `aShareThatNeverReachesLinkedInDoesNotUseTheCeiling` (fails on `a603099`). |
| J5 | Consider | `amplify-jobs/handlers.bal:99-108` | A payload that can't be converted (never changes) is retried `maxAttempts` times before FAILED. | Won't fix: existing `badPayloadRetriesThenFails` codifies it; 8 cheap retries, no external call. |
| J6 | Consider | `amplify-jobs/service.bal:94-98` | A failed `Idempotency-Key` purge isn't fed to the DB breaker (`recordDbFailure`). | Won't fix: cosmetic; the next DB call feeds it. |
| J7 | Consider | `amplify-jobs/database.bal:128-131` | The single-connection lock client is outside the breaker and inherits `maxConnectionLifeTime = 1800`: Hikari can retire the idle lock session mid-run (lock silently dropped), and a failed unlock leaves a reentrant lock count that blocks other replicas. `FOR UPDATE SKIP LOCKED` still keeps two runs off the same rows, and phase 1 runs one replica. | Won't fix now. Proposal for multi-replica: lock client with `maxConnectionLifeTime = 0` and close/reopen the client when `release()` fails. |
| J8 | Consider | `amplify-jobs/service.bal` | `/runs`, `/maintenance/*` have no caller auth; exposure rests on Project visibility (checked: `apps/.choreo/component.yaml` `networkVisibilities: [Project]`, `workload.yaml` `project`, no host port in Compose). | Won't fix: by design until caller auth (CLAUDE.md, M9/M10). All three are idempotent (advisory lock / `IF NOT EXISTS` / upserts). |
| D1 | Should fix | `V010__recognition_upkeep.sql:45-71` | Concurrent ledger appends (jobs score pass + PO decision in api) each re-ranked from their own snapshot: the later commit kept ranks computed without the earlier one's points (two people at rank 1, wrong `points_to_top_n`) until the next append; opposite row-lock orders could deadlock. | **Fixed + IT. V012**: `pg_advisory_xact_lock` first in `apply_ledger_entry`, `rerank`, `rebuild`. `testConcurrentLedgerAppendsKeepRanksConsistent` (fails without V012). |
| D2 | Should fix | `V009__partition_maintenance.sql:229` (+ :104, :175) | Daily upkeep takes ACCESS EXCLUSIVE on `connection.provider_token` (a new token day every day) and `audit.audit_log` (verified: `CREATE TABLE ... PARTITION OF` conflicts with ACCESS SHARE) with no `lock_timeout`. Behind one long reader the request queued forever and every audit insert and token write in amplify-api queued behind it. Two concurrent upkeep calls also raced on the same `CREATE TABLE`. | **Fixed + IT. V012**: `lock_timeout = 5s` on the six upkeep functions, advisory lock in `run_partition_maintenance`. `testUpkeepGivesUpOnALockInsteadOfQueueing` (V011: waits to `statement_timeout`; V012: `lock timeout` < 10 s). |
| D3 | Should fix | `amplify-database/main.bal:140-150` | The runner silently skipped a misnamed script (`V12__x.sql`, `V012__Add.sql`) and applied two `V012__*` scripts in name order. | **Fixed + test.** Any non-matching `.sql` or duplicate number stops the run. 3 unit tests + resources. |
| D4 | Consider | V002–V008 grants | App roles hold privileges no code uses: `DELETE` on `messaging.outbox`, `sharing.*`, `connection.member_connection` (api, jobs); `INSERT/UPDATE` on `messaging.idempotency_key` and `DELETE` on `connection.oauth_state` (jobs). Matches the data model's "rw" cells, so it is a design decision. | **Handoff** H3 (proposed revokes). |
| D5 | Consider | V001 | `PUBLIC` keeps `TEMPORARY` on the database (default). | Won't fix; add `REVOKE TEMPORARY ON DATABASE ... FROM PUBLIC` with H3 if wanted. |
| D6 | Consider | `V003__connection.sql:88` | `config.int_setting` raises on a non-integer value, which would break `member_connection_v` and the upkeep. amplify-api validates every int setting (`settings.bal`), so it can't happen through the app. | Won't fix; defense-in-depth option: regex-guard the cast in a later migration. |
| D7 | Consider | `V008__...sql:75` + claim query | Claim orders by `id` but the partial index is on `next_attempt_at`. Fine at pilot volume. | Won't fix; if the queue grows: `CREATE INDEX ... ON messaging.outbox (id) WHERE status = 'PENDING'`. |
| D8 | Consider | V003/V008 | No DEFAULT partitions: if upkeep stops for 7 days, token inserts fail (3 months for audit). | Won't fix (by design, ADR-002); the "partition-maintenance failures" alert covers it; restore runbook now runs upkeep first. |
| D9 | Consider | `V009` header | Says "amplify-cron"; scripts are immutable. | Won't fix. |
| D10 | Consider | `docs/migrations/README.md:4`, migrations README | Script ranges stale (S001–S003, V011). | **Fixed.** |
| I1 | Should fix | 4 Ballerina `Dockerfile`s, `compose.yaml:18,135,185`, `scripts/test-all.sh:85`, `it-scheduler.sh:40`, `load-test.sh:28` | Base/runtime images on floating tags (`eclipse-temurin:21-jre-alpine` moves weekly; `postgres:18`, `ballerina/ballerina`, `wso2am`, `k6`). Only the scheduler was digest-pinned. | **Fixed + check.** Tag + `@sha256` everywhere; `check-descriptors.sh` now fails on an unpinned `FROM` (Amplify components + chat-stub) or compose `image:`. Verified it flags the old jobs Dockerfile. |
| I2 | Should fix | ADR-026 risk, runbook §7 | Scheduler `job_history` grows forever; the only purge was a manual curl. `DELETE /jobs/{id}/history?before=` needs a caller with a clock (no scheduler template has one), and only amplify-api may call the scheduler. | **Fixed + IT.** `amplify-scheduler/history-retention.sql`: 30-day self-trimming `AFTER INSERT` statement trigger on the scheduler's own DB (+ index on `started`). Compose one-shot `scheduler-retention` (api waits for it); Choreo: once from the scheduler DB console (runbook §7). `scripts/it-scheduler-history.sh` (real pinned image; old rows go on the scheduler's own insert; fails without the SQL); wired into `test-all.sh` tier 3. |
| I3 | Consider | `scripts/test-all.sh:86`, `it-scheduler.sh:41` | Unbounded `until pg_isready` loops hang forever if the container dies. | **Fixed** (60 s bound, logs on failure). Verified with `bash -n` and the history IT. |
| I4 | Consider | `scripts/test-all.sh:111` | `pkill -f mock_linkedin` kills any mock on a shared machine. | Won't fix (integrator-only script). Option: run the mock with `exec` so `$!` is the JVM. |
| I5 | Consider | Dockerfiles | No `HEALTHCHECK`; Choreo uses console probes, Compose defines healthchecks. | Won't fix. Console: point the jobs readiness probe at `/ready` (H6). |
| I6 | Consider | `compose.yaml` | "Only api :9090 and mock :19091 on the host" wasn't enforced. | **Fixed + check.** `check-descriptors.sh` fails on any other host port or a non-loopback bind (optional `apim` profile allowed). Verified with an injected `0.0.0.0:5432`. |
| I7 | Consider | Dockerfiles | `java -jar` without `-XX:MaxRAMPercentage` (JVM default heap = 25 % of the container limit). | Won't fix; tune once Choreo memory limits are set. |
| I8 | Should fix | `docs/runbooks/operations.md` §8 | Restore steps didn't match the runner: "`make seed`" for Choreo, no dry run, no note that the runner re-sets role passwords, no upkeep after restoring an old snapshot (missing token/audit partitions), no double-post warning for shares published after the snapshot. | **Fixed** (docs only; no automation invented). §7 updated for I2; `resilience-targets.md` jobs `/ready` row. |
| I9 | Consider | `amplify-jobs/openapi.yaml:5-7` | Description still named "Choreo Scheduled Task today". | **Fixed.** |

Reviewed and fine: ADR-025 run shape (in-process flag + session advisory lock, stale release, `SKIP LOCKED` claims, attempts counted at claim and given back on DEFER, row-level re-read before any external call, accepted double-post window); 401 → revoke + `NEEDS_RECONNECT`; 429/5xx/timeout/open breaker → share stays QUEUED, RETRY with equal-jitter backoff, `RETRIES_EXHAUSTED` on the final attempt; no HTTP-level retries; run budget 240 s + 11 s < 300 s lease < 300 s scheduler deadline; log hygiene (`check-logs-pii.sh` clean, notes never carry tokens/URLs/commentary); C4 `IS NOT DISTINCT FROM`; SECURITY DEFINER functions (owner `amplify_migrate`, `search_path = pg_catalog, pg_temp`, `format(%I/%L)`, revoked from PUBLIC, jobs-only); token drop rule `max(expires_at) + grace`; UTC partition bounds; `security_invoker` views; runner checksums, per-script transaction, advisory lock, trusted-file exception; chat-stub; Dockerfiles `USER 10014`, no secrets in layers, `.dockerignore` drops `Config.toml`.

## Tests added

- **amplify-jobs unit (+20):** `ready_test.bal` (6: `/ready` 503 + body, gating, run-config defaults/lease/nonsense, longest call); `handlers_test.bal` (14: panic releases flag+lock, Chat not configured, missing/archived/closed campaign, card rejected, sharing off / LinkedIn or keys not configured, missing/already-published share, token row gone, undecryptable token → `RETRIES_EXHAUSTED`/`TOKEN_KEY`, ceiling not spent by a failed decrypt, retryable on final attempt, daily ceiling spent, no point rule / bad time, time budget hands rows back, settings parsing). Fakes: `PanickingRunStore`, `CountingLock`, `PublishedTodayRunStore`, `MemStore.dropTokens`.
- **amplify-database unit (+3):** misnamed script, duplicate version, shipped scripts well-formed.
- **amplify-database IT (+7, `invariants_test.bal`):** V012 applied; constraints reject bad rows (C4 pending/rejected amplify, self-review, reject reason, https evidence, one claim per URL, published xor failed, commentary cleared, engagement required, three-way filter, ledger reason/award/no-PAID/reference/reversal, campaign window/owner, citext email, token ref pair, oauth state, nonce length, outbox DONE/status, setting key, announcement sent xor failed, UUIDv7 defaults); grants denied per role as `amplify_readonly`, `amplify_api`, `amplify_jobs` (tokens, connections, commentary, messaging, audit, config, upkeep, rebuild, campaign delete, ledger/audit rewrite, announcement writes, forged system audit, password setter, `CREATE` in public, direct partition access); definer functions pinned/owned/private + `lock_timeout` + views invoker + `amplify_migrate` owns every relation; partition guards and UTC bounds (Chicago evening on Oct 31 → November partition, token day bounds, today never dropped); concurrent ledger appends (D1); upkeep gives up on a held lock (D2).
- **Scheduler IT (+1):** `scripts/it-scheduler-history.sh`.
- **Checks:** `check-descriptors.sh` digest pins + host ports.

## Coverage

| Package | Before | After |
| --- | --- | --- |
| amplify-jobs (unit, `bal test --code-coverage`) | 62.48 % (333/533 lines) | **75.43 %** (436/578) — handlers 90.5 → 99.3, run 92.5 → 95.3, ports 23.4 → 41.6, ready 96.4 |
| amplify-database (unit) | 10.20 % (10/98) | 17.92 % (19/106) |
| amplify-database (IT, `--groups integration --code-coverage`) | 66.33 % (65/98) | 66.04 % (70/106) |
| chat-stub (unit) | 90.57 % (48/53) | 90.57 % (48/53) |

(The jobs/database unit runs count the IT functions as passing no-ops when IT is off, as before.)

## Commands and results

All from `apps/amplify`; Postgres = `docker run -d --name amplify-rv-jobsdb-pg -e POSTGRES_PASSWORD=postgres -p 127.0.0.1:55434:5432 postgres:18`; mock = `mock_linkedin` with the `tier_it` config on 19190/19191. Both removed afterwards; the mock's `Dependencies.toml` restored.

| Command | Before (`a603099`) | After |
| --- | --- | --- |
| `cd amplify-jobs && bal test --code-coverage` | 25 pass / 0 fail | **45 pass / 0 fail** |
| `cd amplify-database && bal test --code-coverage` | 8 pass / 0 fail | **18 pass / 0 fail** |
| `cd local/chat-stub && bal test --code-coverage` | 2 pass / 0 fail | 2 pass / 0 fail |
| `cd amplify-database && BAL_CONFIG_VAR_ITENABLED=true BAL_CONFIG_VAR_DBPORT=55434 BAL_CONFIG_VAR_DBPASSWORD=postgres BAL_CONFIG_VAR_DBSSLMODE=DISABLE bal test --groups integration` | 7 pass / 0 fail | **14 pass / 0 fail** |
| `cd amplify-jobs && AMPLIFY_IT=true AMPLIFY_IT_DB_PORT=55434 AMPLIFY_IT_PG_CONTAINER=amplify-rv-jobsdb-pg bal test --groups integration,db-down-it` | 3 pass / 0 fail | 3 pass / 0 fail |
| `scripts/it-scheduler-history.sh` | n/a | **1 pass** (fails without the SQL) |
| `scripts/check-descriptors.sh` | in sync | in sync (5 components; new checks catch an unpinned Dockerfile and a stray host port) |
| `scripts/check-logs-pii.sh` | 0 flagged | 0 flagged (61 calls) |
| `docker compose -p rv-jobsdb-configcheck --env-file <dummy> config` | — | valid; host ports only 9090 and 19091 |

Regression proof: the J2/J4 tests fail on the original `run.bal`/`handlers.bal`; the D1/D2 ITs (and the
lock_timeout invariant) fail with V012 removed; the I2 IT fails with an empty retention script.

## New migrations

- `V012__recognition_lock_maintenance_timeout.sql` — doc: `docs/migrations/2026-10-17-v012-recognition-lock-maintenance-timeout.md` (context, changed files, verify, revert).

## HANDOFF

- **H1 (amplify-common successor → amplify-jobs):** once the `amplify_common` release after 0.5.0 is published and jobs moves to it, pass `targetTitle: c.title` in the `publishShare` call in `amplify-jobs/handlers.bal` (the `linkedIn.publishShare(bearer, {...})` block, ~lines 223-230; `c` may be `()`, so `c is () ? () : c.title`). Not done here: `ShareCommand.targetTitle` isn't in 0.5.0.
- **H2 (amplify-common successor + amplify-domain → amplify-jobs):** add a key-rotation re-seal maintenance step using `TokenCipher.reseal` / `activeKeyId` (new after 0.5.0): during `POST /maintenance/partitions` (or a separate endpoint), re-encrypt `provider_token` rows whose `key_id` isn't the active key, so old keys can retire before their partitions drop. Needs an amplify-domain repository method (select by `key_id <> active`, update `ciphertext/nonce/key_id` with the same AAD) and a test with two keys. Not done here: the API isn't in 0.5.0.
- **H3 (architecture / data model owner):** decide on least-privilege revokes (D4/D5). Proposed `V0NN`: `REVOKE DELETE ON messaging.outbox, sharing.share_request, sharing.engagement, sharing.engagement_verification, connection.member_connection FROM amplify_api, amplify_jobs; REVOKE INSERT, UPDATE ON messaging.idempotency_key FROM amplify_jobs; REVOKE DELETE ON connection.oauth_state FROM amplify_jobs; REVOKE TEMPORARY ON DATABASE <db> FROM PUBLIC;` — first check no api/domain test cleans up with DELETE as an app role, then update the grants table in `phase1-data-model.md`.
- **H4 (architecture):** `phase1-data-model.md` "As built (M3, V001–V010)" → mention V011/V012 (recognition advisory lock, upkeep `lock_timeout`).
- **H5 (projects/linkedin):** pin `mock_linkedin/Dockerfile` bases by digest (same digests as here); the descriptor check skips it until then.
- **H6 (Choreo console, ops):** run `amplify-scheduler/history-retention.sql` once on the scheduler DB after the scheduler's first deploy (and after each version bump); set the amplify-jobs readiness probe to `GET /ready` and liveness to `GET /health`.
