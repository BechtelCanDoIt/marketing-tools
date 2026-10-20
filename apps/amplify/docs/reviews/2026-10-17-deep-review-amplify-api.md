# Deep review: amplify-api (2026-10-17)

Branch `rv-api` off `feat/phase1-build` @ `a603099`. Reviewer: Claude (agent), for Scott Bechtel.

## Scope

Everything under `apps/amplify/amplify-api/`: every `.bal` file in the root package and in
`modules/auth`, `modules/scheduler`, `modules/utils`, `openapi.yaml`, every test, `tests/Config.toml`. Plus
the one row of `architecture/solution/Phase 1/activity-matrix.md` where the doc disagreed with the code.

Built against the published `amplify_common 0.5.0` and `amplify_domain 0.1.0` from the shared local
repository. Nothing in amplify-common, amplify-domain, amplify-jobs or amplify-database was edited; what they
need is in the HANDOFF list.

## Method

1. Read the ADRs (004, 009, 010, 019, 022, 023, 024, 025, 026, 028), the activity matrix, leaderboards.md,
   the threat model notes in `token-and-oauth-notes.md` and the deployment checklist, and the M11b section
   of `docs/testing/load-test-2026-10.md`.
2. Checklists applied: WSO2 Digital coding standards, integration boundary (auth, correlation id,
   idempotency, feedback), WSO2 Digital code review (security blocking items first).
3. Read every resource against its openapi operation, its `x-roles`, its `matrix.bal` row and its
   activity-matrix row; followed every `{id}`/`{employeeId}` to the ownership check; compared every input
   bound in the spec with the code; walked the idempotency, settings, scheduler sync, roster and LinkedIn
   paths for races and failure modes.
4. Fix loop: each real finding got a fix and a regression test. Each regression test was then checked to
   **fail with its fix reverted** (a script swapped each fix back out and ran the one test; all 13 failed
   as expected, and the drift guard failed against the original `openapi.yaml` and again with `PENDING`
   removed from the `schedulerSync` enum). Then a second pass over the whole diff, which found one more
   issue (finding 7's first version also dropped the ETag when no roster is configured at all; fixed and
   tested).

What held up well: the JWT verifier is tight (RS256 pinned before any claim is read, signature before
`iss`, dev issuer only ever checked against dev keys, fail-closed `environment` default, JWKS stale-key
serving with a breaker). Default deny in the matrix works, and the generated auth matrix test covers every
route × role. Every "own" read and write uses `principalOf(ctx)`. SQL is all parameterized in the domain
package. Problem details never carry raw errors.

## Findings

Severity: **Blocking** / **Should fix** / **Consider**. Line numbers are after the fix.

| ID | Severity | Where | Finding | Status |
| --- | --- | --- | --- | --- |
| 1 | Should fix | `outbound.bal:259`, `:266` | The roster call put the viewer's email in the query unencoded. A `+` in the local part reached One WSO2 as a space (wrong or no team) and an `&` could add query parameters. A roster body that failed to parse put the parse error message, which can echo body values (emails), into the warn log. | Fixed + test (`testRosterQueryEncodesTheEmail`, `testLeaderboardRosterDegradation`) |
| 2 | Should fix | `handlers.bal:130` | `PATCH /campaigns/{id}` checked `version` and then called the domain `updateCampaign`, which re-reads the row and locks on whatever version it finds. An edit committed between the check and the update was silently overwritten (lost update). Now the patch is applied to the checked row and updated with `expectedVersion = body.version`. | Fixed + test (`testPatchLosesNoConcurrentEdit`) |
| 3 | Should fix | `scheduler_sync.bal:150` | SchedulerSync read settings through the 5 s cache. A reader that loaded the rows just before a commit could refill the cache after the save cleared it, and the push then sent the old schedule while answering `SYNCED`. The sync now always reads the committed rows (`freshSettings`). | Fixed + test (`testSyncPushesCommittedSettingsNotTheCache`) |
| 4 | Should fix | `settings.bal:122` | Same race for every other reader: pre-commit rows could land in the cache after `forgetSettings`, so a kill switch flipped on this replica could read back the old value for up to 5 s. The cache now carries a generation bumped by every local save; a read started before the save isn't cached. | Fixed + test (`testSettingsReadBeforeASaveIsNotCached`) |
| 5 | Should fix | `handlers.bal:179`, `openapi.yaml:990` | `returnTo` accepted `/\evil.example` (browsers treat `/\` as `//`: an open redirect once One WSO2 navigates there), plus whitespace and control characters. The spec pattern `^/[^/]` allowed the same. Code and pattern now refuse backslash, whitespace and control characters; `/` alone is allowed in both. | Fixed + test (`testConnectStartRefusesOpenRedirects`); contract tightened |
| 6 | Should fix (known gap) | `handlers.bal:193`, `outbound.bal:127` | No server-side `redirect_uri` re-check. `POST /connections/linkedin/complete` now takes an optional `redirectUri` (the callback page the browser landed on); when sent it must equal the configured URI, else 422 `OAUTH_REDIRECT_MISMATCH` (checked before the state is consumed). Startup now refuses a `linkedinRedirectUri` that isn't absolute HTTPS (HTTP only with `environment = local`) or that has a query, fragment, credentials or whitespace. One WSO2 should start sending `redirectUri`. | Fixed + test (`testConnectCompleteFlowAndStateRules`, `testRedirectUriStartupRules`); additive contract change |
| 7 | Should fix | `reads.bal:218` | A leaderboard degraded by a roster outage (`teamStatus = UNAVAILABLE`) carried the standings ETag, so the next `If-None-Match` got a 304 and the browser kept the missing My Team until the points changed. A body degraded by an outage now has no ETag and is `no-store`. With no roster configured at all (before D13) the body keeps its ETag, so current behaviour and load numbers don't change. | Fixed + test (`testLeaderboardRosterDegradation`, `testLeaderboardWithoutRosterConfiguredKeepsItsEtag`) |
| 8 | Should fix | `reads.bal:178` | The 304 had no `ETag` or `Cache-Control` (RFC 9110 §15.4.5 says send what the 200 would have). | Fixed + test (`testLeaderboardEtagCacheControlAndRevalidation`) |
| 9 | Should fix | `outbound.bal:164`, `openapi.yaml:872` | `/ready` reported unconfigured jobs/roster breakers as `CLOSED` (ADR-028 says not configured = -1 on the gauge). And the spec's `BreakerState` had no `NOT_CONFIGURED`, though the code already sent it for both LinkedIn breakers; `ReadyStatus.breakers` was missing `database`, `linkedinOAuth`, `linkedinApi`. **The spec was wrong**: fixed the spec, and the code side for jobs/roster. | Fixed + test (`testReadyReportsEveryBreakerPerContract`, drift guard) |
| 10 | Should fix | `openapi.yaml:830` | `x-stable-codes` was missing codes the API answers: `SCHEDULER_UNAVAILABLE`, `METHOD_NOT_ALLOWED`, `INVALID_EMPLOYEE_ID`, `INVALID_POST_URN`, `INVALID_MEMBER_URN`, `INVALID_EMAIL`, `INVALID_UUID`, `SHARE_NOT_QUEUED`, `PAID_NOT_ALLOWED`, `ALREADY_ANNOUNCED`, `ANNOUNCEMENT_NOT_QUEUED` (plus the new `OAUTH_REDIRECT_MISMATCH`). **Spec was wrong**: added them. | Fixed + test (`testStableCodesMatchWhatTheCodeEmits`) |
| 11 | Should fix | `tests/contract_drift_test.bal` (new) | No guard against enum drift (the earlier `schedulerSync` missing `PENDING`). The api's own value sets are now named singleton-union types (`SyncStatus`, `JobResult`, `TeamStatus`, `TeamScope`, `RunTrigger`, `BreakerReport`), and the test reads them from the Ballerina source and compares both ways with the openapi enums; domain enums are compared through their constants and `is` checks; stable codes are compared both ways with the code constants and the domain codes. | Fixed (new test, proven to fail on drift) |
| 12 | Should fix | `reads.bal:310` | A malformed `employeeId` in `GET /team/{employeeId}/history` answered 422 `INVALID_EMPLOYEE_ID`; the spec lists 400 for that operation and every other malformed path is 400. **Code was wrong**: now 400 `VALIDATION_FAILED`. | Fixed + test (`testHistoryScope`) |
| 13 | Should fix | `idempotency.bal:58`, `:82` | Idempotency-key store failures (the key store is the database) never counted against the DB breaker, and the errors went to the log without `resilience:loggable`. | Fixed + test (`testIdempotencyStoreFailuresCountAgainstTheDbBreaker`) |
| 14 | Should fix (task) | `json_body.bal:66`, `reads.bal:207`, `idempotency.bal`, `service.bal` | `/leaderboard` (~700 B) and most other reads cross the 512-char JDK 21 writer window fixed for `/team` in M11b. Moved onto `jsonBody`/`okJson`: `/leaderboard`, `/me`, `/me/points`, `/campaigns`, `/campaigns/{id}` (GET, PATCH, DELETE), `/me/shares`, `/me/external-shares`, `/po/external-shares`, `/po/point-rules`, `/team/{id}/history`, `/po/dashboard`, `/admin/announcements`, `/admin/settings` (GET, PUT). Every POST response and replay goes through `jsonResponse`, which now uses `jsonText`. ETag, `Cache-Control` and 304 are kept. Removed the wrong comment at the old `service.bal:483` ("the one response past the json serializer's buffer window"). | Fixed + byte-identity assertions on every moved read (`assertStandardJson`) and `testJsonResponseKeepsTheStandardBytes` |
| 15 | Should fix | `modules/auth/matrix.bal:91`, `activity-matrix.md` | The history row said "Non-PO: employeeId must equal the caller" / "R own", but the code (and leaderboards.md, ADR-019) also allow a member of the caller's roster team, or anyone with `team.visibility = COMPANY`. **The docs were wrong**: updated the `useCase` note and the matrix row. | Fixed (docs) |
| 16 | Consider | `reads.bal:378` | The PO dashboard cache was keyed by any valid `YYYY-MM` and never evicted. Now drops expired entries and caps at 24 months. | Fixed + test (`testDashboardCacheIsBoundedAndCacheable`) |
| 17 | Consider | `interceptors.bal:148`, `json_body.bal:56` | Responses with personal data (emails, points) had no `Cache-Control`. Every response without one is now `no-store`; the two cacheable reads also send `Vary: Authorization` so a second user on the same browser never gets the first user's copy. | Fixed + test (`testMeAndPointsShapesAndNoStore`, leaderboard and dashboard tests) |
| 18 | Consider | `handlers.bal:100` | PATCH didn't enforce `tags` `maxItems: 20` from the spec (POST did). | Fixed + test (`testPatchValidationAndArchive`) |
| 19 | Consider | `interceptors.bal:194` | A 405 problem had title "Bad Request" and an inline code string. Now "Method Not Allowed" and the `METHOD_NOT_ALLOWED` constant, which puts it under the drift guard. | Fixed (no test: the interceptor answers 403 for an unknown method before dispatch can 405) |
| 20 | Consider (tests) | `tests/auth_test.bal:26`, `tests/service_test.bal:21` | The test HTTP clients had Ballerina's client cache on. Once `/leaderboard` answered 200 with `private, max-age=30`, the client served it to the later anonymous and breaker-open calls, so those tests weren't reaching the server. Cache off in tests; the auth sample test now tells an interceptor 403 from a use-case 403 (`TEAM_SCOPE`). | Fixed |
| 21 | Consider | `amplify-domain` `store/settings.bal` `claimIdempotencyKey` | If the key is released (5xx) between the `INSERT … ON CONFLICT DO NOTHING` and the `SELECT`, the `queryRow` finds nothing and the caller gets 503. | Handoff (H2) |
| 22 | Should fix | `handlers.bal` `completeConnect` → `amplify-domain` `connection` | The sealed token row is inserted before `completeConnection`. When that fails (`MEMBER_ALREADY_LINKED`, version conflict) the live LinkedIn token stays in `provider_token` until its partition is dropped. | Handoff (H3) |
| 23 | Consider | `modules/scheduler/schedule.bal`, ADR-026 item 3 | The minimum interval only applies to `@every`. A cron string such as `* * * * *` passes for `maintenance.schedule` (ADR says ≥ 1 h) and for `run.schedule` when `minRunIntervalSeconds` > 60. That follows the ADR's wording, so not changed here. | Handoff (H4, ADR decision) |
| 24 | Consider | `idempotency.bal` | If releasing a key fails during a DB flap after a 5xx, the key stays "running" for 24 h and the client gets 409 `IDEMPOTENCY_IN_PROGRESS` on retry with that key. ADR-024 accepts this as the safe direction. | Won't fix (ADR-024 decision; a new key works) |
| 25 | Consider | `reads.bal` leaderboard ETag | The ETag tracks only `period:standing_version`. A `leaderboard.top_n` change whose rebuild trigger is `DEFERRED` keeps the old ETag until the next standings change. The documented ETag format is part of the contract, so left as is. | Won't fix (contract; rebuild bumps the version) |
| 26 | Consider | `handlers.bal` `claimExternalShare` | `campaignId` on a claim isn't checked for existence (no cross-context FK by design, ADR-005). | Won't fix (by design) |
| 27 | Info | ADR-025 | Generic outbox reprocess: confirmed the only API path is `POST /admin/announcements/{id}/retry`; ADR-025 leaves "reprocess FAILED outbox rows" to the runbook (manual SQL). No endpoint added, per instructions. | No change |

Counts: 0 Blocking; 16 Should fix (15 fixed, 1 handoff); 10 Consider (5 fixed, 2 handoff, 3 won't fix); 1 Info. In total 20 fixed, 3 handoff, 3 won't fix, 1 info, 0 open.

## Contract (openapi.yaml) changes

All backward compatible for clients; two of them tighten input:

- `BreakerState` adds `NOT_CONFIGURED`; `ReadyStatus.breakers` lists `database`, `linkedinOAuth`, `linkedinApi` (the code already sent them).
- `Problem.code.x-stable-codes` adds the 12 codes in finding 10.
- `ConnectComplete.redirectUri` (optional, new) and 422 `OAUTH_REDIRECT_MISMATCH`.
- `ConnectStart.returnTo` pattern is now `^/([^/\\\s][^\\\s]*)?$` (tightened: no backslash or whitespace; `/` alone allowed).
- `/leaderboard`: the 304 documents `ETag` and `Cache-Control`; the description says when a degraded body has no ETag.
- Info block: responses are `Cache-Control: no-store` unless the operation says otherwise.

## Tests added

New files: `tests/read_fakes.bal` (fakes for every read seam, a fake One WSO2 roster on the test listener,
fake LinkedIn adapter, test token cipher, OAuth state / token / announcement repositories),
`tests/reads_test.bal`, `tests/writes_test.bal`, `tests/connect_idempotency_test.bal`,
`tests/contract_drift_test.bal`. Changed: `tests/fakes.bal` (concurrent-edit hook, key-store failure switch),
`tests/scheduler_sync_test.bal` (version-conflict switch), `tests/auth_test.bal` and `tests/service_test.bal`
(client cache off), `tests/Config.toml` (`rosterUrl` → the fake roster).

Newly covered branches: leaderboard OK / NO_TEAM / UNAVAILABLE / not configured, ETag, 304, period 400;
team TEAM / COMPANY / no roster, every query 400; history own / teammate / stranger 403 `TEAM_SCOPE` /
roster down / PO / COMPANY / bad id 400; `/me`, `/me/points`, `/ready` shapes; dashboard cache and month
400; list validation for campaigns, review list, announcements; PATCH race, stale version, 404, 400s, 422s,
archive and archived 409s, archived campaign hidden from employees; register validation; share kill switch;
point rule / adjustment / reversal validation; `SELF_REVIEW` 403; announcement retry (kill switch, 202, 409,
404, 400); settings version conflict 409 and value 422s; connect start/complete (open redirect, redirect
mismatch, foreign state, single use, provider rejected 422, provider down 503, not configured 503), remove
connection 204; idempotency 4xx stored and replayed, in progress 409, key length 400, 5xx released,
key-store failure → 503 and breaker open; replay bytes; contract drift both ways.

## Commands and results

Run inside `apps/amplify/amplify-api` (`openssl` on PATH; ports 9090 and 9591):

| Command | Before | After |
| --- | --- | --- |
| `bal test --code-coverage` | 44 passed, 0 failed (36 root + 8 `scheduler`) | **75 passed, 0 failed, 0 skipped** (67 root + 8 `scheduler`) |
| Coverage, package | 70.43 % (1374 / 1951 lines) | **83.08 %** (1655 / 1992) |
| Coverage, `amplify_api` root module | 64.32 % | **80.79 %** |
| Coverage, `amplify_api.auth` | 95.95 % | 95.95 % |
| Coverage, `amplify_api.scheduler` | 86.16 % | 86.16 % |
| `scripts/lint-openapi-names.sh` (from `apps/amplify`) | OK | OK |
| `scripts/check-logs-pii.sh` | n/a | 62 log calls scanned, 0 flagged |

Not run, per the shared-machine rules: `bal push`, `scripts/test-all.sh`, `make` targets, Compose, the
scheduler IT (`AMPLIFY_IT`).

## HANDOFF

**H1. ID-token validation and PKCE in `completeConnect` (amplify-common published API, then amplify-api).**
`linkedin:IdTokenValidator` and `TokenGrant.idToken` exist in the amplify-common source but not in the
published 0.5.0, so nothing here calls them. Wiring once amplify-common is published (and `Ballerina.toml`
bumped):
1. `startConnect` (`handlers.bal`): pass the state's `nonce` into the authorize request
   (`adapter.authorizationUrl(state.state, nonce = state.nonce)`, or whatever signature common ships). For
   PKCE: generate a `code_verifier` (43-128 chars, unreserved set), store it with the state, send
   `code_challenge = BASE64URL(SHA-256(verifier))`, `code_challenge_method = S256`. Storing the verifier needs
   a `codeVerifier` column/field on `connection.oauth_state` / `connection:OAuthState` (amplify-database
   migration + amplify-domain), returned by `consume`.
2. `completeConnect`, right after `adapter.exchangeCode(body.code)` (add `codeVerifier = state.codeVerifier`
   for PKCE): if `grant.idToken` is a string, validate it with the common validator against issuer
   `https://www.linkedin.com/oauth`, audience `linkedinClientId`, the LinkedIn JWKS, and
   `nonce == state.nonce`; on failure return `unprocessable(OAUTH_STATE_INVALID, …)` (no token stored, the
   provider/validator message only in the log). Then require `idToken.sub` to equal `profile.sub` from
   `userInfo` (or drop the userinfo call and take `sub`/member URN from the ID token).
3. New configurables: `linkedinJwksUrl` (default `https://www.linkedin.com/oauth/openid/jwks`) and
   `linkedinIssuer`; the validator's JWKS client should get a breaker and show up in `/ready` as
   `linkedinJwks` (add it to `BreakerReport` users and to `ReadyStatus.breakers`; the drift test will flag
   the spec otherwise).
4. Tests: extend `FakeLinkedIn` in `tests/read_fakes.bal` to return an ID token signed by the test key
   (`mint()` in `jwt_support.bal`) and cover bad signature, wrong `aud`, wrong `nonce`, `sub` mismatch.

**H2. amplify-domain `store:claimIdempotencyKey` (finding 21).** When the `INSERT … ON CONFLICT DO NOTHING`
affects 0 rows and the following `SELECT` finds no row (`store:isNoRows`), retry the insert once instead of
returning the `NoRowsError`. Today the API answers 503 for that request.

**H3. amplify-domain `connection` token write (finding 22).** Insert the sealed token in the same
transaction as the connection change: either `ConnectionRepository.save` takes the `StoredToken` for a
`completeConnection` change, or `completeConnection` takes the `TokenRepository` and the domain deletes the
token row when the connection write fails. Then `completeConnect` stops calling `tokenRepository().insert`
itself.

**H4. ADR-026 item 3 (finding 23).** Decide whether the minimum-interval rule should also bound cron and
descriptor schedules (`* * * * *` every minute for maintenance passes today). If yes, `scheduler:checkSchedule`
needs a "shortest gap between two fires" check for 5-field cron; the change is in this package, but the ADR
wording should change first.

**H5. One WSO2 UI.** Send `redirectUri` (the callback page URL without its query) on
`POST /connections/linkedin/complete`; make sure `returnTo` is only ever navigated as a same-origin path.

**H6. Docs owner (`architecture/security/token-and-oauth-notes.md` §2 gap 3 and the deployment checklist
row "exact redirect URI match").** Update to: server-side redirect URI assertion present when the client
sends `redirectUri`, and `linkedinRedirectUri` validated at startup (this review, finding 6). Not edited
here: outside this package's scope.
