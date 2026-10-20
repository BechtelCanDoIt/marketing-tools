# Deep review: amplify-domain (2026-10-17)

Branch `rv-domain` off `feat/phase1-build` @ `a603099`. Reviewer: Claude (agent), for Scott Bechtel.

## Scope

Every `.bal` file in `amplify-domain` (root module, the eight bounded contexts, `store`, and all unit and integration tests), checked against:

- the migrations in `amplify-database/migrations` V001 to V011 (columns, constraints, grants per role), read-only
- ADR-005, 009, 010, 012 to 019, 021, 024, 025, 028, 029, 031
- `phase1-data-model.md`, `activity-matrix.md`, `leaderboards.md`, `po-dashboard.md`
- `threat-model-phase1.md`, `token-and-oauth-notes.md`, `deployment-security-checklist.md` (known gaps)
- the WSO2 Digital coding standards and code review checklist

Nothing outside `amplify-domain` was changed. Changes other packages need are in the HANDOFF list.

## Method

1. Baseline: unit tests with coverage, then a private PostgreSQL 18 (`amplify-rv-domain-pg`, 127.0.0.1:55433), migrated by the amplify-database IT runner, then the domain `integration` group and a combined unit + IT coverage run.
2. Read every file. For each repository: SQL against the real schema and the grants of the role that runs it, transaction boundaries (aggregate + outbox + audit in one transaction, ledger + recognition in one, B12), optimistic locking, idempotent appends (ADR-029), unique-key mapping to domain codes, casts, stream handling, error mapping, PII and token handling.
3. Each real finding got a fix and a regression test that fails before and passes after (the concurrency test was run against the code with the fix commented out to prove it).
4. Unit and integration tests re-run, then the whole diff reviewed a second time; the second pass found and fixed a misleading code comment (R-01 lock rationale) and a test that depended on a hard-coded outbox id.

What held up well: every write path already commits aggregate, outbox and audit in one transaction; unique-key races map to stable domain codes (`CAMPAIGN_ALREADY_REGISTERED`, `SHARE_ALREADY_QUEUED`, `EVIDENCE_ALREADY_CLAIMED`, `MEMBER_ALREADY_LINKED`, PK race on connect as `VERSION_CONFLICT`); SQL is parameterized everywhere with the right `timestamptz` / `uuid` casts; tokens and commentary never reach logs, audit or events; the ledger append is idempotent by reference and a second reversal is a no-op through `points_ledger_reverses_uk`.

## Findings

Severity: **Blocking** (correctness, security or data loss on a real path), **Should fix**, **Consider**.

| ID | Severity | Where | Finding | Status |
|----|----------|-------|---------|--------|
| R-01 | Blocking | `modules/scoring/repository.bal:227`, `modules/recognition/repository.bal:97`, `modules/store/store.bal:128` | Two ledger appends at once (jobs score pass and a PO adjust/approve, or two PO actions) both run `recognition.rerank`, a period-wide UPDATE. Each holds its own standing row and waits for the other's: PostgreSQL reported `deadlock detected` in the new test, and without a deadlock the second re-rank can store ranks computed from a snapshot that misses the first one's row. Fix: `store:lockRecognition` takes a transaction-scoped advisory lock (key 4242101) before `apply_ledger_entry` and before `recognition.rebuild` (now wrapped in a transaction). It polls `pg_try_advisory_xact_lock` with a growing sleep (max 10 s, then a plain error) instead of blocking, and sets `idle_in_transaction_session_timeout = 5 s` locally so a holder that stops committing (see R-13) can't block every append forever. | Fixed + test (`testConcurrentLedgerAppendsNeitherDeadlockNorMisrank`, fails with "deadlock detected" without the lock) |
| R-02 | Should fix | `modules/external_sharing/service.bal:123` | `markAmplified` had no self-review check, so a PO could mark their own approved claim amplified and pay themselves the `OWN_POST_AMPLIFIED` top-up. Threat model 4.6 claims this is mitigated; the DB `CHECK` only covers `decided_by`. Fix: optional `markedBy` parameter, `SELF_REVIEW` when it is the claimant; `amplifyExternalShare` and `amplifyWithPoints` pass the PO. | Fixed + test (unit `claimantCantMarkOwnClaimAmplified`, IT `testPoCantAmplifyOwnClaim`) |
| R-03 | Should fix | `external_sharing/repository.bal:115`, `campaign/repository.bal:104`, `sharing/repository.bal:117`, `connection/repository.bal:130`, `scoring/repository.bal:109`, `store/settings.bal:90`, `store/audit.bal` | Update audit rows wrote `after` only; the threat model's audit sample and the review brief require before and after. Fix: each update uses PostgreSQL 18 `RETURNING old.*` (no extra read, same statement as the version check) and passes `before` through a new defaulted `auditOf(..., before = ())` parameter. | Fixed + test (`testAuditBeforeAfterAndVersionConflictRollsBack`) |
| R-04 | Should fix | `modules/store/store.bal:43,89` | Known M10 gap: nothing verified the database server certificate. `DbConfig` now has `sslRootCert` (CA PEM path) and `sslMode` defaults to `VERIFY_FULL`; `secureSocketOf` passes `rootcert` only for `VERIFY_CA` / `VERIFY_FULL`; `verifiesServer` lets a component warn at start-up. Local `DISABLE` still works. api and jobs pass their own `dbSslMode` configurable (default `REQUIRE`), so the deployed behaviour changes only with the HANDOFF H-1. | Fixed + test (unit `tlsVerifiesTheServerByDefault`, `nonVerifyingModesIgnoreTheCaAndSayNo`); config in api/jobs = Handoff H-1 |
| R-05 | Should fix | `modules/connection/repository.bal:183` | Known M10 gap: `TokenCipher.needsRotation()` has no production caller, so key rotation never re-encrypts. Domain half done: `PgTokenRepository.updateSeal(old, resealed)` swaps ciphertext, nonce and key id on the same row (same AAD, same partition), guarded by the old `key_id`, so a concurrent re-seal or a deleted row is a no-op. The cipher half (`TokenCipher.reseal`) is in amplify_common 0.6, not in the published 0.5.0 this package builds against. | Partly fixed + test (`testTokenUpdateSealIsGuardedByTheOldKey`); `resealToken` + jobs caller = Handoff H-2 |
| R-06 | Should fix | `modules/announcements/repository.bal:110` | The admin announcement retry reset the `CampaignRegistered` outbox row even while a run had it `IN_PROGRESS`, clearing `locked_by`, so a second run could send the Club card again while the first was still sending. Fix: skip `IN_PROGRESS` rows and return `ANNOUNCEMENT_NOT_FAILED` ("being sent right now"); a missing row stays `NOT_FOUND`. | Fixed + test (`testAnnouncementRequeueSkipsARowInProgress`) |
| R-07 | Should fix | `scoring/queries.bal:63`, `recognition/queries.bal:125`, `external_sharing/queries.bal:97`, `store/store.bal:175` | `historyOf`, `teamPage` and `claimsForReview` sent `page * size` straight to SQL: a negative page or size became a raw SQL error, and a huge page overflowed `int` (a panic). A page past the end also reported `total = 0`. Fix: `store:pageWindow` (negative page = 0, size below 1 = 1, overflow-safe) and a count fallback past the last page, as `listCampaigns` already did. | Fixed + test (unit `pageWindowNormalizesBadInput`, IT `testPagingGuardsAndTotalPastTheEnd`) |
| R-08 | Consider | `modules/store/settings.bal:97` | `updateSettings` documented `NOT_FOUND` but returned `VERSION_CONFLICT` for an unknown key. Now `NOT_FOUND` when the key doesn't exist. | Fixed + test (in `testAuditBeforeAfterAndVersionConflictRollsBack`) |
| R-09 | Consider | `modules/store/settings.bal:148` | `claimIdempotencyKey`: if the holder released the key between this caller's failed insert and its read, the read raised a raw `NoRowsError`. Now it claims the key, or reports it as still running. | Fixed (race window too narrow to force in a test; logic covered by the existing idempotency IT) |
| R-10 | Consider | `modules/campaign/queries.bal:197`, `scoring/queries.bal`, `external_sharing/queries.bal` | `dashboardCampaigns`, `recentCorrections` and `claimsOf` ordered without a unique tie-breaker, so `LIMIT` could return a different set on equal timestamps. Added `id` / `reference`. | Fixed (ordering only) |
| R-11 | Consider | `tests/integration_test.bal:339` | `testLedgerAppendUpdatesRecognitionInOneTransaction` assumed nobody else on the shared board sits between its two employees; it failed once other tests leave standings behind. Now compares against the next better total on the board. | Fixed (test) |
| R-12 | Should fix | tests | No test covered two writers on one aggregate, or rollback of outbox + audit on a version conflict. | Fixed + test (`testTwoWritersOneWinsTheOtherConflicts`, `testAuditBeforeAfterAndVersionConflictRollsBack`) |
| R-13 | Blocking (platform) | Ballerina 2201.13.3 runtime / ballerinax/postgresql 1.19.1 | With 8 transactions started in parallel (isolated strands, the same shape as concurrent HTTP requests), a few per 48 fail with `ConcurrentModificationException` inside SQL execution, and occasionally a transaction reports success but never commits (probe: 47 of 48 outbox + audit rows with 0 errors, once in 8 runs; separately a connection left idle in transaction holding locks). Reproduced with plain SQL and no Amplify code (`testRuntimeProbeConcurrentTransactions`, group `runtime-probe`). Same result with one client per strand. Not fixable inside this package. Mitigation here: R-01's lock polling and idle timeout keep it from hanging all ledger writes. | Handoff H-3 |
| R-14 | Consider | `modules/sharing/repository.bal:93` | `recordPublish` returns the raw unique-violation error on a second publish; amplify-jobs (`handlers.bal:236`) depends on `store:isUniqueViolation` for it, and in that case the share request stays `QUEUED` forever. Mapping it would break the consumer. | Won't fix here (consumer contract); Handoff H-5 |
| R-15 | Consider | `scoring/queries.bal:100`, `sharing/queries.bal:104`, `external_sharing/queries.bal:149` | PO dashboard tiles `pointsByAction`, `shareHealth`, `reviewThroughput` scan whole tables by time (`points_ledger.created_at` has only `(employee_id, created_at)`; `share_request` has no index on `published_at` / `failed_at`). Fine at phase 1 volume. | Handoff H-4 |
| R-16 | Consider | `modules/connection/repository.bal:166` | The api inserts the token row, then saves the connection in a second transaction; a failed save leaves an orphan encrypted row until its partition drops. | Won't fix (partition drop is the documented backstop; a combined port would change the api flow) |
| R-17 | Consider | `modules/connection/service.bal:112` | `revoke` on an already revoked connection bumps the version and queues another `ConnectionRevoked`. Downstream it is harmless (shares already failed); jobs relies on getting a `ConnectionChange` back. | Won't fix (behaviour relied on by jobs) |
| R-18 | Consider | `tests/integration_m5_test.bal` | Several M5 ITs never close their client. Test-only; the pool closes at JVM exit. | Won't fix |
| R-19 | Consider | `modules/store/store.bal:128` | `lockRecognition` holds a pool connection while it waits (up to 10 s). Under heavy PO + jobs contention that can exhaust a 10-connection pool. Ledger writes are short, so waits are milliseconds in practice. | Won't fix (noted; revisit if the M11 load profile adds concurrent ledger writes) |

Counts: Blocking 2 (R-01 fixed, R-13 handoff), Should fix 7 (R-02, R-03, R-04, R-06, R-07, R-12 fixed; R-05 partly fixed + handoff), Consider 10 (R-08, R-09, R-10, R-11 fixed; R-15 handoff; R-14, R-16, R-17, R-18, R-19 won't fix).

## Tests added

Unit (`bal test`):

- `modules/store/tests/store_test.bal` (new, 7 tests): TLS options and `verifiesServer`, `pageWindow`, `auditOf` before/after, `arrayLiteral` escaping, error mapping (`isUniqueViolation`, `isNoRows`, `versionConflict`), `ts` and `truncate`.
- `modules/external_sharing/tests/external_sharing_test.bal`: `claimantCantMarkOwnClaimAmplified`.

Integration (`tests/integration_review_test.bal`, new, group `integration`):

- `testConcurrentLedgerAppendsNeitherDeadlockNorMisrank` (R-01): 6 rounds x 8 parallel appends; no deadlock / busy error, stored ranks equal a fresh dense rank, every standing equals its employee's ledger sum (B12).
- `testTwoWritersOneWinsTheOtherConflicts` (R-12): two POs approve one claim at once; one wins, the other gets a domain code, one event and one audit row.
- `testAuditBeforeAfterAndVersionConflictRollsBack` (R-03, R-08, R-12): before/after on external share, campaign, settlement and settings; stale write leaves no outbox or audit row; unknown setting and missing ledger entry are `NOT_FOUND`.
- `testPoCantAmplifyOwnClaim` (R-02).
- `testAnnouncementRequeueSkipsARowInProgress` (R-06).
- `testTokenUpdateSealIsGuardedByTheOldKey` (R-05).
- `testPagingGuardsAndTotalPastTheEnd` (R-07).
- `testRebuildUnderTheLockMatchesIncrementalTotals` (R-01, rebuild path).
- `testAnnouncementWriterQueueSendAndFail`: the jobs-side `PgAnnouncementWriter` and `statusesOf` (were untested).
- `testEmployeeUpsertKeepsFirstSeen`: `PgEmployeeRepository` (was untested).
- `testRuntimeProbeConcurrentTransactions` (group `runtime-probe`, not in `integration`): the R-13 reproducer, prints counts, asserts nothing.

## Coverage

Unit only (`bal test --code-coverage`):

| Module | Before | After |
|--------|--------|-------|
| announcements | 66.29% | 67.05% |
| campaign | 48.24% | 48.05% |
| connection | 40.34% | 38.87% |
| external_sharing | 46.44% | 46.21% |
| identity | 29.63% | 29.63% |
| recognition | 26.58% | 25.45% |
| scoring | 44.44% | 43.84% |
| sharing | 54.18% | 53.75% |
| store | 0.00% | 20.98% |
| **Total** | **41.27%** | **42.15%** |

Repository code only runs against PostgreSQL, so unit-only numbers dip slightly where repository lines were added. The combined run is the meaningful one:

Unit + integration (`AMPLIFY_IT=true AMPLIFY_IT_DB_PORT=55433 bal test --code-coverage`):

| Module | Before | After |
|--------|--------|-------|
| announcements | 79.78% | 97.73% |
| campaign | 96.08% | 96.09% |
| connection | 96.22% | 96.36% |
| external_sharing | 95.13% | 95.67% |
| identity | 55.56% | 100.00% |
| recognition | 94.30% | 94.55% |
| scoring | 93.06% | 93.15% |
| sharing | 97.61% | 97.63% |
| store | 66.67% | 73.17% |
| **Total** | **91.30%** | **93.20%** |

## Commands and results

```sh
# private Postgres
docker run -d --name amplify-rv-domain-pg -e POSTGRES_PASSWORD=postgres -p 127.0.0.1:55433:5432 postgres:18
# migrate (amplify-database IT runner, read-only use)
cd amplify-database && BAL_CONFIG_VAR_ITENABLED=true BAL_CONFIG_VAR_DBPORT=55433 \
  BAL_CONFIG_VAR_DBPASSWORD=postgres BAL_CONFIG_VAR_DBSSLMODE=DISABLE bal test --groups integration   # 7 passing
cd amplify-domain
bal test --code-coverage                                                    # unit
AMPLIFY_IT=true AMPLIFY_IT_DB_PORT=55433 bal test --groups integration      # integration
AMPLIFY_IT=true AMPLIFY_IT_DB_PORT=55433 bal test --code-coverage           # unit + integration coverage
AMPLIFY_IT=true AMPLIFY_IT_DB_PORT=55433 bal test --groups runtime-probe    # R-13 reproducer
docker rm -f amplify-rv-domain-pg
```

| Run | Before | After |
|-----|--------|-------|
| Unit (`bal test`) | 64 passing, 0 failing (51 module tests + 13 root ITs that return early without `AMPLIFY_IT`) | 83 passing, 0 failing (59 module tests + 24 root ITs returning early) |
| Integration group | 13 passing, 0 failing | 23 passing, 0 failing (run twice in a row on the same database) |
| Unit + integration with coverage | 64 passing | 83 passing |

## HANDOFF

**H-1 (R-04) DB TLS verify-full configuration**, `amplify-api/database.bal:48,125` and `amplify-jobs/database.bal:37,104,128`.
Change: add `configurable string dbSslRootCert = "";` and pass `sslRootCert: dbSslRootCert` into both `store:newClient` calls (jobs has two). Change the `dbSslMode` default from `postgresql:REQUIRE` to `postgresql:VERIFY_FULL`. At start-up, `log:printWarn` when `!store:verifiesServer(config)` and the host isn't local. Mount the managed Postgres CA as a Choreo file mount and set `BAL_CONFIG_VAR_DBSSLROOTCERT` per environment. `compose.yaml:13` keeps `BAL_CONFIG_VAR_DBSSLMODE: DISABLE`. Then update `deployment-security-checklist.md:100,113` from "Met w/ exception" to met.
Why: the security checklist requires `sslmode=verify-full`; `REQUIRE` encrypts but accepts any server. Needs amplify_domain republished first.

**H-2 (R-05) Token re-seal on use**, `amplify-domain/modules/connection/service.bal` (after amplify_common 0.6 is published) and `amplify-jobs/handlers.bal:217`.
Change: bump the domain dependency to amplify_common 0.6 and add next to `openToken`:
`public isolated function resealToken(crypto:TokenCipher cipher, StoredToken token) returns crypto:SealedToken|error?` calling `cipher.reseal({ciphertext, nonce, keyId}, {tokenId, ownerId, provider})` (returns `()` when the row already uses the active key). In jobs, after a successful `openToken`, call `resealToken` and, when it returns a value, `PgTokenRepository.updateSeal(token, resealed)` (already in this branch, guarded by the old `key_id`). A failed or no-op re-seal is logged without token material and never fails the share. Add a jobs port method for `updateSeal`.
Why: closes `token-and-oauth-notes.md` claim 2 / threat model AMP-R2 (rotation is by partition drop only). The domain half can't call `TokenCipher.reseal` while it builds against published 0.5.0.

**H-3 (R-13) Ballerina runtime race under concurrent transactions**, platform (Ballerina 2201.13.3, ballerinax/postgresql 1.19.1, ballerinai/transaction).
Change: (a) reproduce with `AMPLIFY_IT=true bal test --groups runtime-probe` in amplify-domain and raise it with the Ballerina team / check for a fixed patch release; (b) new migration `V012__idle_in_transaction_timeout.sql` (amplify-database owner): `ALTER ROLE amplify_api SET idle_in_transaction_session_timeout = '60s'; ALTER ROLE amplify_jobs SET idle_in_transaction_session_timeout = '60s';` so any connection the runtime leaves idle in a transaction releases its locks, not just the recognition lock holders covered in this branch; (c) the M11 load test should add a concurrent-write scenario (PO approvals and adjustments in parallel) and compare committed rows to 2xx responses.
Why: under parallel transactions some report success without committing, or fail with `ConcurrentModificationException`; a leaked open transaction can hold row locks indefinitely. Every transactional write in api and jobs shares this exposure.

**H-4 (R-15) Dashboard indexes**, new migration `V012+` (amplify-database owner).
Change: `CREATE INDEX points_ledger_created_at_idx ON scoring.points_ledger (created_at);` `CREATE INDEX share_request_published_at_idx ON sharing.share_request (published_at) WHERE published_at IS NOT NULL;` `CREATE INDEX share_request_failed_at_idx ON sharing.share_request (failed_at) WHERE failed_at IS NOT NULL;` `CREATE INDEX external_share_decided_at_idx ON external_sharing.external_share (decided_at) WHERE decided_at IS NOT NULL;`
Why: tiles 4, 7 and 2 filter by time on whole tables; cheap now, a seq scan per dashboard load as the ledger grows. Confirm with `EXPLAIN` on production-like volume before adding.

**H-5 (R-14) Share stuck QUEUED after a duplicate publish**, `amplify-jobs/handlers.bal:235-238`.
Change: when `recordPublish` fails with a unique violation, mark the share request published or failed (for example `markFailed(share, PROVIDER_REJECTED, "DUPLICATE_ENGAGEMENT", now)` through `update`) instead of returning `done` with the request still `QUEUED`. If a domain helper is preferred, add `sharing:PgShareRepository.recordDuplicatePublish` in amplify-domain (additive) in a follow-up.
Why: the employee sees "on its way" forever and can't retry (`SHARE_ALREADY_QUEUED`).

**H-6 (R-02) threat model wording**, `architecture/security/threat-model-phase1.md:252`.
Change: mitigation for 4.6 should read "`amplified` is PO-only, only on an `APPROVED` claim, and never by the claimant (`SELF_REVIEW`, `external_sharing:markAmplified`)".
Why: the old text claimed a control the code didn't have; it now does.

## Public API

Additive only. New: `store:DbConfig.sslRootCert` (defaulted), `store:secureSocketOf`, `store:verifiesServer`, `store:lockRecognition`, `store:pageWindow`, `store:RECOGNITION_LOCK_KEY`, `store:RECOGNITION_IDLE_TIMEOUT_MS`, `store:RECOGNITION_LOCK_WAIT_SECONDS`, trailing defaulted `before` on `store:auditOf`, trailing defaulted `markedBy` on `external_sharing:markAmplified`, `connection:PgTokenRepository.updateSeal`. No port (object type) changed, so consumers' fakes still type-check.

Behaviour changes callers can see: `DbConfig.sslMode` default is `VERIFY_FULL` (api and jobs always pass it explicitly); the amplify use cases reject a PO amplifying their own claim (`SELF_REVIEW`); `requeue` refuses an `IN_PROGRESS` row (`ANNOUNCEMENT_NOT_FAILED`); `updateSettings` returns `NOT_FOUND` for an unknown key; a ledger append can fail with "The leaderboard is busy; retry" after 10 s of lock contention; `recognition:rebuild` now runs in its own transaction (jobs calls it outside one).
