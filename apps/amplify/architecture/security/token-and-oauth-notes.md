# WSO2 Amplify — Token & OAuth notes (plan M10)

Verification notes for the security-critical claims in the threat model and the deployment checklist. Every claim below was checked against the code on `feat/phase1-build` (2026-10-17), and re-checked after deep review rounds 1 and 2 ([review docs](../../docs/reviews/)); the **file** is named so the control can be re-verified. Where a control is partial or missing it is marked **gap** and the required work is stated — nothing here claims a control the code does not have.

Paths are under `projects/marketing-tools/apps/amplify/` unless noted. Companion docs: [WSO2 Amplify Threat Model.docx](../../docs/security/WSO2%20Amplify%20Threat%20Model.docx), [WSO2 Amplify Application Deployment Security Checklist.docx](../../docs/security/WSO2%20Amplify%20Application%20Deployment%20Security%20Checklist.docx).

## Claim verification summary

| # | Claim | Verdict | Where |
| --- | --- | --- | --- |
| 1 | LinkedIn member tokens encrypted with AES-256-GCM, random nonce, per-row `key_id` | **Verified** | `amplify-common/modules/crypto/token_cipher.bal` |
| 2 | Key rotation re-encrypts old rows | **Verified** (deep review 2026-10-17) | re-seal on use in `amplify-jobs/handlers.bal` `resealOnUse`; rotation pass in `POST /maintenance/partitions` (`amplify-jobs/types.bal` `rotateTokenKeys`) |
| 3 | OAuth `state` is single-use, 10-min TTL, employee-bound | **Verified** | `amplify-domain/modules/connection/oauth_state.bal` |
| 4 | Remove Connection deletes the token row immediately; a new token row commits with the connection change | **Verified** | `amplify-domain/modules/connection/repository.bal` `saveTx` |
| 5 | Evidence URL: HTTPS-only, no IP literals, never fetched server-side | **Verified** | `amplify-common/modules/types/evidence_url.bal` |
| 6 | OAuth validates an ID token; PKCE | **ID token: available behind a flag** (`linkedinIdTokenValidation`, default `false`). **PKCE: not available** to web clients at LinkedIn | `amplify-api/handlers.bal` `checkIdToken`, `amplify-api/outbound.bal`, `amplify-common/modules/linkedin/id_token.bal` |
| 7 | Legal/Privacy consent copy signed off | **Open** | needs owner (Legal/Privacy) |

---

## 1. Token encryption at rest

**Verified facts** (`amplify-common/modules/crypto/token_cipher.bal`, `…/crypto/gcm.bal`):

- **Algorithm AES-256-GCM.** `KEY_BYTES = 32`, `NONCE_BYTES = 12` (96-bit), `TAG_BITS = 128`. GCM runs through the JDK `javax.crypto.Cipher` via Ballerina Java interop because `ballerina/crypto` exposes no AAD parameter (`gcm.bal:35-78`).
- **AAD binds the ciphertext to its row:** `AAD = token_id | owner_id | provider` (`aadBytes`, 149-156). A ciphertext copied into another row will not decrypt — so a DB-only attacker cannot move a token between connections.
- **Fresh random nonce per encryption:** `randomNonce()` (161-164) derives 12 bytes from a v4 UUID (SecureRandom-backed). No nonce reuse; tests assert freshness and tamper detection (`crypto/tests/token_cipher_test.bal`).
- **Per-row `key_id`:** `seal()` writes the `currentKeyId`; `open()` looks the key up in the ring by the stored `key_id` and errors on an unknown id (111-113). `provider_token.key_id` is stored per row (`amplify-domain/modules/connection/repository.bal:163-166`).
- **Key source:** `tokenKeys` / `tokenCurrentKeyId` configurables (`amplify-api/outbound.bal:64-65`, `amplify-jobs/config.bal`). Format `keyId:base64Key[,keyId:base64Key…]`; `keyFromBase64` requires standard base64 of exactly 32 bytes; `init()` validates ids 1-64 chars, no duplicate ids, exactly 32-byte keys, and that `currentKeyId` is in the ring (72-91).
- **Seal/open helpers:** `connection:sealToken` / `openToken` / `resealToken` bind the AAD to `{tokenId, ownerId, provider}` (`amplify-domain/modules/connection/service.bal`).
- **Token row commits with the connection change** (api review H3, round 2 item 8). `completeConnect` hands the sealed token to `connection:completeConnection(..., token)`, which puts it on `ConnectionChange.tokenToInsert`; `PgConnectionRepository.save` inserts it first, inside the connection's transaction. A failed connection write leaves no orphan token row (domain IT `testConnectionWriteFailureLeavesNoTokenRow`). The api no longer calls `tokenRepository().insert` on its own.

### Claim 2 — rotation (wired, deep review 2026-10-17)

**Old-key rows are re-sealed under the active key in two places**, so an old key can leave the ring before its partitions drop:

- **Re-seal on use.** Right after a share opens a token (`openToken`), amplify-jobs calls `resealOnUse` (`amplify-jobs/handlers.bal`). It wraps `connection:resealToken` (which calls `TokenCipher.reseal` with the same AAD and returns `()` when the row already uses the active key) and `PgTokenRepository.updateSeal`. The update is guarded by the old `key_id`, so two concurrent re-seals are harmless. It's best effort: a failure is logged without token material and never fails the share.
- **Rotation pass in maintenance.** `POST /maintenance/partitions` runs `rotateTokenKeys` after partition upkeep. It pages through `PgTokenRepository.sealedWithOtherKey` (keyset paging, up to 10,000 rows per pass) and re-seals each row through `connection:resealStaleTokens`. The response carries `token_rotation {status, resealed, skipped, failed}`: `status` is `DONE`, `PARTIAL` (row cap hit; the next pass carries on), `NOT_CONFIGURED` (no token keys) or `FAILED` (the database refused). It's never fatal to the maintenance call. A row that doesn't open (key missing from the ring, or tampered) is counted in `failed` and left alone.

Tests: domain unit `resealTokenMovesAnOldKeyRowToTheActiveKey`, `resealStaleTokensPagesThroughOldKeyRows`; domain IT `testResealStaleTokensAgainstTheDatabase`; jobs `aTokenOnAnOldKeyIsResealedOnUse`, `rotationStepReportsAndNeverFails`.

**What's left:** retiring a key is still a manual step. Wait until `token_rotation` reports `DONE` with `failed = 0` and no row carries the old `key_id`, then remove the key from the ring ([operations.md](../../docs/runbooks/operations.md) §2). Threat-model residual **AMP-R2** now covers only the backup window and master-key custody.

### Grant check

`amplify_readonly` has **no** grant on `connection.provider_token` (only the PII-masked views expose connection status) — see the data model's grants table and [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md).

## 2. OAuth `state` (LinkedIn, S2)

**Verified facts** (`amplify-domain/modules/connection/oauth_state.bal`, `amplify-api/handlers.bal`):

- **Generation:** `newOAuthState(...)` sets `state` and `nonce` to `randomToken()` = 64 hex chars from two v4 UUIDs (244 bits of randomness), plus `returnTo` and optional `pendingCampaignId` (`oauth_state.bal:74-90`; issued at `handlers.bal:156`).
- **Storage:** `PgOAuthStateRepository.issue()` inserts into `connection.oauth_state` (113-120).
- **TTL = 10 minutes:** `OAUTH_STATE_TTL_SECONDS = 600`; `expiresAt = now + 600` (30, 82).
- **Single-use:** `consume(state, employeeId, now)` is one `DELETE … WHERE state=? AND employee_id=? AND expires_at > now RETURNING …` — read and burn in a single statement (122-142). Unknown, used, expired or belonging to another employee → `()` → API returns `OAUTH_STATE_INVALID` (409, "expired or already used; start again") (`handlers.bal:179-183`).
- **Employee binding:** `consume` requires `employee_id` = the verified principal's id (`p.employeeId`), so a stolen `state` is useless to another user.
- **Input bounds:** `returnTo` must start with one `/`, ≤512 chars, with no backslash (`/\host` reads as `//host`), whitespace or control characters (`isRelativePath`, api review finding 5); `code` 0-2048 and `state` 32-128 on complete (168). Provider errors never echo the token or body (`providerFailure`, 218-225).

### OAuth flow: what exists and what LinkedIn doesn't offer (updated after deep review 2026-10-17)

1. **Server-side `redirect_uri` check: present when the client sends it.** `POST /connections/linkedin/complete` takes an optional `redirectUri` (the callback page the browser landed on, without its query). When it's sent and doesn't equal `linkedinRedirectUri` exactly, the API answers **422 `OAUTH_REDIRECT_MISMATCH`**, before the state is consumed (`completeConnect`, `amplify-api/handlers.bal`). At startup, `checkRedirectUri` (`amplify-api/outbound.bal`) refuses a `linkedinRedirectUri` that isn't absolute `https://` (plain `http://` only with `environment = local`) or that has a query, fragment, credentials, whitespace or a backslash; it runs whenever LinkedIn is configured. The same URI goes on the authorize request and the token exchange, so LinkedIn still matches it at exchange time too. **The One WSO2 Amplify module sends `redirectUri`** (api review H5) on branch `feat/amplify-module` (commit `fa716b93`, `AmplifyConnectCallbackPage.tsx`), which isn't merged to One WSO2 `main` yet. Until it is deployed, the check is skipped and matching rests on LinkedIn.
2. **ID-token validation: available, off by default.** With `linkedinIdTokenValidation = true`, `completeConnect` validates `grant.idToken` after the code exchange and userinfo (`checkIdToken`, `amplify-api/handlers.bal`): RS256 signature against the LinkedIn JWKS, `iss`, `aud` = `linkedinClientId`, `exp`/`iat`. A missing or invalid token is refused with 422 `OAUTH_STATE_INVALID` (the reason goes only to the log); JWKS unreachable gives 503 `DEPENDENCY_UNAVAILABLE`; and the token's `sub` must equal userinfo's `sub`. The JWKS URL (`linkedinJwksUrl`, default `https://www.linkedin.com/oauth/openid/jwks`) and issuer (`linkedinOidcIssuer`) are configurable. The validator's breaker is reported in `/ready` as `linkedinIdTokenJwks`, not gating. Tests: `amplify-api/tests/id_token_test.bal` (good, bad signature, wrong `aud`, expired, missing, `sub` mismatch, flag off). It defaults to off because `mock_linkedin` doesn't issue ID tokens yet (round 2 item 10), so it can't be on locally or in e2e. Turn it on per environment once a real LinkedIn app has been seen to return a valid `id_token`.
3. **Issuer discrepancy (common RC-13).** LinkedIn's live discovery document (`https://www.linkedin.com/oauth/.well-known/openid-configuration`) gives `iss` = `https://www.linkedin.com/oauth`, while the table on LinkedIn's OIDC docs page gives `https://www.linkedin.com`. The default (`linkedin:LINKEDIN_OIDC_ISSUER`) is the discovery value; `linkedinOidcIssuer` overrides it if LinkedIn changes it. Confirm against a real token before turning validation on.
4. **No nonce.** amplify-domain generates and stores `oauth_state.nonce`, and amplify-common has `authorizationUrlWithNonce` and `validate(..., expectedNonce)`, but the API doesn't send or check a nonce (`validate(idToken, ())`). LinkedIn doesn't document a `nonce` parameter on `/oauth/v2/authorization`. Wire it only after a real LinkedIn app is seen to echo `nonce` in the ID token (common review H3).
5. **No PKCE, because LinkedIn doesn't offer it to web clients.** LinkedIn documents PKCE only for native clients: a separate `/oauth/native-pkce/authorization` endpoint, loopback `redirect_uri` only, turned on per app on request ([Authenticating with OAuth 2.0 for Native Clients](https://learn.microsoft.com/linkedin/shared/authentication/authorization-code-flow-native)). The web 3-legged flow lists no `code_challenge`, and the discovery document has no `code_challenge_methods_supported`. Amplify is a confidential web client, so the code exchange is protected by the client secret plus `state`.

**Assessment:** `state` binding, the confidential client and (when sent) the redirect-URI check carry the flow in phase 1. ID-token validation is ready to switch on; nonce and PKCE wait on LinkedIn.

## 3. LinkedIn token lifecycle

- **Scopes (least privilege):** `openid profile w_member_social` — write-only posting; **no read/analytics scope** in phase 1 (ADR-018). Consequence: Amplify cannot verify a share still exists; a deleted share keeps its points until PO reverses by hand.
- **Remove Connection deletes the token immediately — verified.** `removeConnection()` applies `remove()` (sets `removedAt`, clears `currentToken`, `version+1`) and calls `repo.save(...)` (`connection/service.bal:128-177`). `PgConnectionRepository.saveTx` runs, in the same transaction, `DELETE FROM connection.provider_token WHERE token_id=? AND issued_on=?` — comment: "Reconnect and Remove delete the old token row right away; the partition drop is the backstop" (`repository.bal:133-140`). So removal is immediate, not just logical.
- **Partition backstop:** daily token partitions are dropped at `max(expires_at) + token_grace_days(5)` by the maintenance job; reconnect also overwrites the old row.
- **Version header:** `LinkedIn-Version: 202610` (`const LINKEDIN_VERSION`, `linkedin/types.bal:25`; header set only on `POST /rest/posts` in `adapter.bal:127-148`). Pinned as data (`linkedinApiVersion`, `amplify-jobs/config.bal:49`); a bump is config-only. Watch/sunset plan: [pilot-readiness.md](../../docs/requirements/pilot-readiness.md) §1.

## 4. Evidence-URL handling (external shares)

**Verified facts** (`amplify-common/modules/types/evidence_url.bal`, `parseEvidenceUrl`, called from `external_sharing/service.bal:55`):

- **HTTPS-only** (`ERR_EVIDENCE_URL_NOT_HTTPS`), max length 2048, control/space chars (≤0x20, 0x7F) rejected.
- **No credentials** (`@` in authority rejected), **no IP literals** — IPv6 bracket form rejected; `validateHost()` rejects a numeric/hex final label (dotted/decimal/hex IPv4) and requires ≥2 labels so `localhost`/single-label is rejected; each label must match a DNS-label regex; host ≤253 chars.
- **Port** parsed and range-checked (1-65535; default 443 dropped).
- **Normalization (C5 / ADR-017):** lowercase scheme+host, strip fragment/trailing slashes, drop tracking params (`utm_*`, `fbclid`, `gclid`, `trk`, `trackingid`, `mc_cid`, `mc_eid`), sort query; detect provider and extract a LinkedIn URN. Uniqueness per normalized `(url, action)` across all employees (`ERR_EVIDENCE_ALREADY_CLAIMED`).
- **Never fetched server-side — verified.** Validation + normalization only; no HTTP client touches the evidence URL (grep clean). The comment states "Amplify never fetches it." So there is **no SSRF surface** in Amplify for the evidence URL.

**Gap (rendering):** whether the UI renders the link with `rel="noopener noreferrer"` and as plain text **cannot be verified from this repo** — there is no Amplify frontend here (the One WSO2 SPA is a separate repo, and its `evidenceUrl` rendering was not found). Required: confirm the render in the One WSO2 module (owner: One WSO2 UI owner). Since the URL is never fetched by Amplify, the risk is limited to how a PO's browser follows it.

## 5. Kill switches (sharing / announcements)

- Constants `sharing.enabled`, `announcements.enabled` (`amplify-api/constants.bal:99-100`); default **true** (`amplify-api/settings.bal:42-44`; seeded `amplify-database/seed/S003__app_settings.sql:31-32`).
- **API gates:** `requestShare` → 409 `FEATURE_DISABLED` "Sharing is paused right now" when off (`handlers.bal:247-249`); `retryAnnouncement` → 409 `FEATURE_DISABLED` when off (384-385).
- **Jobs gates:** `handleCampaignRegistered` defers the outbox row when announcements are off; `handleRepostRequested` defers when sharing is off (`amplify-jobs/handlers.bal:125,183`). Work is **deferred, not lost** — flipping the switch back on drains it.
- Settings are cached (`settingsCacheSeconds`, default 5 s; local save invalidates) so a switch takes effect within ~5 s.

## 6. Health and readiness scopes

- **`amplify-api` `/health`** — always `UP` (liveness). **`/ready`** gates on **`database`** (breaker not open **and** `store:probe` succeeds) **and `jwks`** (breaker not open) only. `jobs`, `roster`, `linkedinOAuth`, `linkedinApi` and `linkedinIdTokenJwks` breakers are **reported but do not fail readiness** (non-fatal degradations, ADR-024). `/ready` also republishes the `amplify_breaker_state` gauges (ADR-028). Both paths are public, GET-only (`matrix.bal:111`).
- **`amplify-jobs` `/ready`** (deep review 2026-10-17, jobs J1) gates on **`database`** only (breaker not open and `store:probe` succeeds); `linkedinApi`, `googleChat` and `runInProgress` are reported, not fatal (`amplify-jobs/service.bal`, `ready.bal`). Compose's healthcheck uses it; the Choreo readiness probe is a console setting.
- **Pool exhaustion fails readiness** in both (R-13 mitigation): HikariCP's "Connection is not available" counts as a transient DB error, so repeated failures open the DB breaker and `/ready` answers 503 (api `testPoolExhaustionFailsReady`, jobs `poolExhaustionFailsReadiness`, jobs IT `realPoolExhaustionTripsTheBreaker`).
- **Scheduler** is an external pinned image (ADR-026); it has no Amplify health code, and no `scheduler` breaker exists.

## 7. Dev-local JWT (brief)

Full detail in [ADR-023](../decisions/ADR-023-dev-local-jwt.md). Verified: `environment` defaults to `"prod"`; `checkDevSwitch()` refuses startup unless `environment == "local"`, and refuses a blank `devIssuer` or one equal to `gatewayIssuer` (`config.bal:93-103`). When on, a token whose `iss` equals the dev issuer is **only** checked against the dev keys (`token.bal:150-156`). The switch is off in every Choreo descriptor (see threat model §2). Minor: the dev path accepts a no-`kid` token against every dev key — gated solely by `environment == "local"`.

## 8. Open items (owners)

| Item | Why open | Owner |
| --- | --- | --- |
| **Legal/Privacy consent copy** (LinkedIn connect + "I certify this is WSO2") | The copy and the data-processing notice for storing a member token need Legal/Privacy sign-off (requirements-map audit **A9**) | Legal/Privacy — **needs owner** |
| **Evidence-link rendering** (§4) | Not verifiable in this repo (One WSO2 UI) | One WSO2 UI owner |
| **Choreo readiness probes** (§6) | Code has `/ready` in api and jobs; the probe paths are set in the console | Scott (console) |
| **One WSO2 sends `redirectUri`** (§2) | Server-side check runs only when the client sends it | One WSO2 UI owner |
| **Turn on ID-token validation** (§2) | Off by default until a real LinkedIn app returns a valid `id_token`; confirm the issuer (RC-13) | Scott |
| **PKCE / nonce** (§2) | Not offered / not documented by LinkedIn for web clients; accepted for phase 1 | Security (accept) |
