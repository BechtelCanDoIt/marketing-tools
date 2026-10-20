# Deep review: amplify-common (2026-10-17)

Branch `rv-common`, based on `feat/phase1-build` at `a603099`. Package `wso2/amplify_common` 0.5.0.

## Scope

Every `.bal` file under `amplify-common`, tests included: `common.bal` plus the modules `types`, `events`, `linkedin`, `googlechat`, `crypto` and `resilience`. That's 3,928 lines before the review.

Out of scope: the callers in `amplify-api`, `amplify-domain` and `amplify-jobs`. I read them only to check how this package is used. Anything they need is listed under HANDOFF.

## Method

1. Read the repo and package `CLAUDE.md`, ADR-018, 020, 022, 024, 025, 028 and 029, `phase1-data-model.md` (event catalogue, grants), `threat-model-phase1.md` and `token-and-oauth-notes.md` (the M10 gaps).
2. Applied the checklists from `wso2-digital-coding-standards`, `wso2-digital-code-review` and `wso2-engineering-governance` (`se-security-review`): secrets, input validation, typed errors, no raw errors or PII in messages, isolation, the license header, `Dependencies.toml`.
3. Checked LinkedIn behaviour against LinkedIn's official docs and the live discovery document, not memory:
   - [Sign In with LinkedIn using OpenID Connect](https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/sign-in-with-linkedin-v2)
   - [OIDC discovery document](https://www.linkedin.com/oauth/.well-known/openid-configuration)
   - [Authorization Code Flow (3-legged OAuth)](https://learn.microsoft.com/en-us/linkedin/shared/authentication/authorization-code-flow)
   - [Authenticating with OAuth 2.0 for Native Clients (PKCE)](https://learn.microsoft.com/linkedin/shared/authentication/authorization-code-flow-native)
   - [Posts API](https://learn.microsoft.com/linkedin/marketing/community-management/shares/posts-api?view=li-lms-2026-09) and the [ArticleContent schema](https://learn.microsoft.com/linkedin/marketing/integrations/ads/advertising-targeting/version/article-ads-integrations?view=li-lms-2026-09#schema)
4. Fix loop. Each real finding got a fix and a regression test. I confirmed every regression test that runs against the old API fails on the old code: I put the original production file back, ran just those tests (RC-02, 04, 05, 06, 07 and 08 all failed), then restored the fix. RC-01, RC-03 and RC-09 add API that didn't exist before, so their tests can't compile against the old code.
5. Re-read the full diff a second time. The second pass found nothing new.

## What's already solid

- **Crypto.** AES-256-GCM goes through `javax.crypto` with a 128-bit tag. Each seal gets a fresh 96-bit SecureRandom nonce (bytes 0-5 and 10-15 of a v4 UUID, so no version or variant bits). The AAD is `token_id|owner_id|provider`, and `|` is refused inside a part, so the encoding is unambiguous. Lookup by `key_id` fails closed. Errors never carry plaintext or key bytes, and the JDK checks the GCM tag (no hand-rolled compare).
- **LinkedIn adapter.** It sends `LinkedIn-Version: 202610` and `X-Restli-Protocol-Version: 2.0.0` on `/rest/posts`, reads the new post from `x-restli-id` through `parsePostUrn`, and escapes little text for the full reserved set. The API and OAuth clients have separate pools and breakers, and the HTTP retry stays at 0 on create calls (ADR-025). Errors carry only status and `serviceErrorCode`.
- **Chat.** Card text goes through `escapeHtml` (`& < > "`), the URL is kept out of every error, and the webhook HTTP retry stays at 0.
- **Ledger (ADR-029).** References are `AMP-` + 43 base64url characters (47 total, fits `varchar(66)`). `ADJ-`/`REV-` + UUIDv7 with 74 random bits. The parse rule matches the ADR.
- **Events.** One builder per catalogue row, keys `<event_type>:<parts>` exactly as in `phase1-data-model.md`. No tokens or commentary in payloads.
- **DbBreaker (ADR-028).** The CLOSED → OPEN → one TRIAL → CLOSED/OPEN machine has a lock around every state change, an injectable clock and an expiry for lost trials. `isTransientDbError` follows the ADR's SQLSTATE list.

## Findings

Severity: **Blocking**, **Should fix**, **Consider**. Line numbers are in the files after the fix.

| ID | Severity | Location | Finding | Status |
| --- | --- | --- | --- | --- |
| RC-01 | Should fix | `modules/linkedin/id_token.bal:89`, `adapter.bal:123`, `types.bal:78` | The `openid` scope is requested, but the ID token in the token response was thrown away and never checked (M10 gap, notes claim 6). | **Fixed + test.** New `IdTokenValidator`: RS256 signature against the cached LinkedIn JWKS (refreshes on age or an unknown `kid`, at most once per 30 s, and the last good keys keep serving), `iss`, `aud` = client id (`azp` required when there are several audiences), `exp`/`nbf`/`iat` with 60 s skew and a 600 s maximum age, a non-blank `sub`, and an optional constant-time `nonce` check. `TokenGrant.idToken` now carries the token. Wiring → H1, H2. |
| RC-02 | Should fix | `modules/types/evidence_url.bal:200` | The `/posts/...-activity-N` branch built a `PostUrn` without `parsePostUrn`, so a long id gave a URN past `URN_MAX_LENGTH` and the 100-character id rule. | **Fixed + test** (`evidencePostsUrnKeepsTheUrnInvariant`) |
| RC-03 | Blocking | `modules/linkedin/adapter.bal:191` | `SHARE`/`SHARE_COMMENTARY` (the D5 fallback) sent `content.article` with only `source`. The Posts API doesn't scrape article links, and `title` is a required field of ArticleContent. Real LinkedIn would refuse every share of those kinds (422 → `PROVIDER_REJECTED`). `mock_linkedin` treats `title` as optional, so local tests never caught it. | **Fixed + test** (`shareArticleAlwaysCarriesATitle`). New `ShareCommand.targetTitle` (defaulted). The article always carries a title, trimmed and cut to 399 characters, with `DEFAULT_ARTICLE_TITLE` as the fallback. Caller → H5. |
| RC-04 | Should fix | `modules/googlechat/client.bal:74` | Plain HTTP was allowed when the URL *started with* `http://localhost` or `http://127.0.0.1`. That let `http://localhost.attacker.example/...` or `http://127.0.0.1.nip.io/...` send the webhook key and token in clear text to a remote host. | **Fixed + test** (`webhookPlainHttpOnlyForExactLoopbackHosts`). Exact host match after stripping user info and port. |
| RC-05 | Consider | `modules/googlechat/card.bal:147` | `isPublicHttpsUrl` accepted `localhost.` (trailing dot) and hex or short IPv4 forms (`0x7f.0.0.1`). | **Fixed + test** (`cardImageRejectsTrailingDotAndNumericHosts`). Strips the trailing dot and refuses any numeric final label. Behaviour change → H8. |
| RC-06 | Should fix | `modules/linkedin/adapter.bal:263` | A token response with a blank `access_token` or `expires_in <= 0` was accepted, then encrypted and stored as a working connection. | **Fixed + test** (`exchangeCodeRejectsUnusableTokenBodies`). Now returns `BAD_RESPONSE`. |
| RC-07 | Consider | `modules/types/ledger.bal:114` | `awardReference` checked trimmed parts for blankness but hashed them untrimmed. ` emp-1` and `emp-1` gave two references, so one action could earn twice if a caller forgot to trim. | **Fixed + test** (`awardReferenceRejectsUntrimmedParts`). Untrimmed parts are refused. The encoding (ADR-029) is unchanged. |
| RC-08 | Consider | `modules/resilience/db_breaker.bal:265` | `loggable` redacted the SQL cause but passed a wrapper's own message through, and wrappers like `"Save failed: " + err.message()` copy the `Detail:` row values into it. | **Fixed + test** (`loggableRedactsWrapperMessages`) |
| RC-09 | Should fix | `modules/crypto/token_cipher.bal:144` | `needsRotation()` had no production caller, and the package had no clean "decrypt with old key, seal with current key" API (M10 gap, notes claim 2, AMP-R2). | **Fixed + test.** New `reseal(sealed, aad)` (returns `()` when the key is current, fails closed on a wrong row or a retired key, fresh nonce, plaintext never leaves the method) and `activeKeyId()`. Wiring → H4. |
| RC-10 | Should fix | `modules/*/tests/*.bal` | The test stub ports collided or sat outside the agreed range. `resilience_test` and `amplify-jobs/tests/webhook_test.bal` both bound 9297, and 9681/9682 were also outside the range. Parallel test runs flaked. | **Fixed.** Now 18210 (LinkedIn), 18211 (Chat), 18212 (resilience), 18213 (JWKS). |
| RC-11 | Consider | OAuth flow | PKCE. LinkedIn documents PKCE only for **native clients**: a separate `/oauth/native-pkce/authorization` endpoint, loopback `redirect_uri` only, and LinkedIn turns it on per app on request. The web 3-legged flow lists no `code_challenge`, and the discovery document has no `code_challenge_methods_supported`. Sources: the native-client and 3-legged pages linked above. | **Won't fix.** Not supported for a web/confidential client. The `state` + client-secret control stays (notes §2). Doc update → H7. |
| RC-12 | Consider | `modules/linkedin/adapter.bal:82` | OIDC `nonce`. `amplify-domain` already generates and stores `oauth_state.nonce`, but it was never sent. LinkedIn's docs don't list `nonce` on `/oauth/v2/authorization`. | **Fixed + test** (library only). `authorizationUrlWithNonce(state, nonce)`, plus `validate(..., expectedNonce)` requires a match when given. Wire it only after checking a real app echoes it → H3. |
| RC-13 | Consider | `modules/linkedin/id_token.bal:33` | LinkedIn's docs table gives `iss` = `https://www.linkedin.com`, while the live discovery document gives `https://www.linkedin.com/oauth`. | **Fixed.** Default is the discovery value. `IdTokenConfig.issuer` is configurable in case LinkedIn changes it. |
| RC-14 | Consider | `modules/linkedin/adapter.bal:227` | `expectStatus` treats any 2xx as success, not just the expected 201. | **Won't fix.** A create without `x-restli-id` is still `BAD_RESPONSE`, so no wrong outcome. |
| RC-15 | Consider | `modules/linkedin/adapter.bal` (`expectStatus`, no-response branch) | A timeout on `POST /rest/posts` is `UNAVAILABLE`, retryable. If LinkedIn accepted the post, the outbox retry posts it again. | **Won't fix.** This is the residual risk ADR-025 item 5 accepts (LinkedIn's duplicate check usually returns 422). |
| RC-16 | Consider | `modules/linkedin/adapter.bal:254` | `Retry-After` on 429 isn't surfaced. | **Won't fix.** Outbox backoff with equal jitter owns retry timing (ADR-025 item 4). |
| RC-17 | Consider | `modules/crypto/token_cipher.bal:182` | Random 96-bit GCM nonces are safe up to about 2^32 seals per key. | **Won't fix.** Phase 1 volume is several orders below that. `reseal` plus rotation keeps it that way. |
| RC-18 | Consider | `README.md` | The README still listed `resilience` as planned. | **Fixed** (doc). |
| RC-19 | Consider | `Ballerina.toml:4` | The package `CLAUDE.md` says to bump the version when the API changes, but the consumers pin `0.5.0` exactly. | **Handoff** (H6). Left at 0.5.0 so the consumers keep building. |

Counts: 1 Blocking, 6 Should fix, 12 Consider (19 findings). By status: 13 Fixed (11 with a regression test, plus RC-10 test infra and RC-18 doc), 5 Won't fix (RC-11, 14, 15, 16, 17), 1 Handoff (RC-19). Three of the fixes (RC-01, RC-09, RC-03) also need caller wiring (H1–H5).

## Public API

Every change is **additive**. Nothing was renamed or removed, and no signature changed.

- `crypto.TokenCipher.activeKeyId()`, `crypto.TokenCipher.reseal(SealedToken, TokenAad) returns SealedToken|error?`
- `linkedin.IdTokenValidator`, `IdTokenConfig`, `IdTokenClaims`, `LINKEDIN_OIDC_ISSUER`, `LINKEDIN_JWKS_URL`, `ID_TOKEN_MAX_LENGTH`
- `linkedin.LinkedInAdapter.authorizationUrlWithNonce(string, string?)` (a class method, not on `ProviderAdapter`, so the fakes in `amplify-jobs/tests/fakes.bal` still type-check)
- `linkedin.TokenGrant.idToken` (`string? = ()`) and `linkedin.ShareCommand.targetTitle` (`string? = ()`), both defaulted, so existing record literals still compile
- `linkedin.DEFAULT_ARTICLE_TITLE`, `linkedin.ARTICLE_TITLE_MAX_LENGTH`

Behaviour that got stricter (same signatures): `buildPostPayload` adds `content.article.title`, `exchangeCode` refuses unusable token bodies, `isPublicHttpsUrl` refuses IP hosts, `awardReference` refuses untrimmed parts, `WebhookClient` init refuses non-loopback plain HTTP, and `loggable` redacts wrapper messages. A grep of the consumers found no test that compares `TokenGrant` or `buildPostPayload` output, and no caller that passes untrimmed award parts (`amplify-domain/modules/scoring/service.bal:103,126` pass parsed values).

`Dependencies.toml` now lists `jwt` (used by the new validator) and `file`/`os` (used only by the ID-token tests, to generate RSA keys with openssl). The `file` module moves from 1.12.0 to 1.13.0. The consumers already resolve 1.13.1 or 1.14.0.

## Tests added

56 new tests, all in this package:

- **crypto (+6):** reseal moves an old row to the current key with a fresh nonce; reseal leaves a current row alone; reseal fails closed on a wrong row or a retired key; open refuses an unknown key, a short nonce and a too-short ciphertext; key-ring id rules; blank AAD parts.
- **linkedin (+36):** ID-token happy path with nonce; 17 data-driven rejections (wrong `iss` or `aud`, several audiences without `azp`, expired, no `exp`, `iat` in the future, too old or missing, `nbf`, missing or blank `sub`, nonce missing or wrong, HS256 and `none` headers, rogue signature, unknown `kid`); several audiences with `azp`; skew window; malformed tokens; key rotation picked up through a JWKS refresh; JWKS unreachable → `UNAVAILABLE`, retryable; blank client id; JWKS parsing; constant-time compare; base64url. Adapter: ID token carried through; 3 unusable token bodies; userinfo bad `sub` and bad body; missing or foreign `x-restli-id`; browser base URL, nonce encoding and `breakers()`; article title (trim, cut, default); repost has no article.
- **googlechat (+5):** exact loopback rule; trailing-dot and numeric image hosts; long title cut; quote escaping; 200 without a message name → `BAD_RESPONSE`, plus `breaker()`.
- **resilience (+5):** wrapper message redaction (and `Hint:`); half-open read, single trial, `reset`, stray trial report; edges of the transient classification; `clientConfig` carrying the settings; gauge values.
- **types (+4):** untrimmed award parts; posts-URN invariant; port and host edges in evidence URLs; shared-kernel helpers (`hasCommentary`, `trimToNil`, `resourceTypeOf`, `HealthStatus`).

The ID-token tests generate RSA key pairs per run with `openssl`, the same way `amplify-api/tests/jwt_support.bal` does, so no key material sits in the repo.

## Coverage and test counts

Command, run in `apps/amplify/amplify-common`: `bal test --code-coverage`. Report: `target/report/test_results.json`.

| Module | Tests before | Tests after | Lines covered/missed before | Before | Lines covered/missed after | After |
| --- | --- | --- | --- | --- | --- | --- |
| types | 49 | 53 | 200 / 4 | 98.04 % | 205 / 1 | 99.51 % |
| events | 4 | 4 | 102 / 0 | 100.00 % | 102 / 0 | 100.00 % |
| linkedin | 13 | 49 | 126 / 11 | 91.97 % | 281 / 6 | 97.91 % |
| googlechat | 12 | 17 | 71 / 1 | 98.61 % | 87 / 0 | 100.00 % |
| crypto | 8 | 14 | 44 / 1 | 97.78 % | 45 / 0 | 100.00 % |
| resilience | 13 | 18 | 146 / 19 | 88.48 % | 156 / 9 | 94.55 % |
| **Total** | **99 pass, 0 fail** | **155 pass, 0 fail** | 689 / 36 | **95.03 %** | 876 / 16 | **98.21 %** |

The lines still missed are URL-encoding error branches (`url:encode` of plain strings can't fail), a key that won't build from a JWK, the `TransientDbRetry` sleep path and the gauge-registration race in `metrics.bal`.

Commands and results:

- `bal test --code-coverage` (baseline, before any change): 99 passing, 0 failing.
- `bal test --code-coverage` (after the fixes): 155 passing, 0 failing.
- Fail-before check: put the old `evidence_url.bal`, `ledger.bal`, `client.bal`, `card.bal` and `db_breaker.bal` back, then `bal test --tests <5 regression tests>`: 0 passing, 5 failing. Old `readTokenBody` condition, `bal test --tests amplify_common.linkedin:exchangeCodeRejectsUnusableTokenBodies`: 2 of 3 cases failing (the third body was already refused). Fixes restored afterwards.

I didn't run `bal push`/`bal pack`, `scripts/test-all.sh` or `make`/`docker compose`.

## HANDOFF

Changes other packages need. I didn't make any of them.

- **H1. Validate the ID token on connect.** In `amplify-api/handlers.bal:184-191` (`completeConnect`), after `exchangeCode`: when an `IdTokenValidator` is configured, call `validate(grant.idToken, expectedNonce)`. Refuse a missing `idToken` while validation is on. Then require `claims.sub == profile.sub` (userinfo) before `sealToken`. On a `ProviderError`, return `providerFailure(...)`. Config in `amplify-api/outbound.bal:87-99`: add `linkedinIdTokenValidation` (boolean, default `false` until H2 lands), `linkedinJwksUrl` (default `linkedin:LINKEDIN_JWKS_URL`) and `linkedinOidcIssuer` (default `linkedin:LINKEDIN_OIDC_ISSUER`). Build `new linkedin:IdTokenValidator({clientId: linkedinClientId, issuer, jwksUrl})`. Add its `breaker()` as `linkedinIdTokenJwks` next to the other breakers at `outbound.bal:143-144` (reported, not readiness-gating, like `linkedinOAuth`). Why: this closes notes claim 6 and threat-model row 2.2.
- **H2. Teach the mock to issue ID tokens.** `projects/linkedin/apps/mock_linkedin` (another project): when scope has `openid`, return an RS256 `id_token` from `/oauth/v2/accessToken` with `iss` `https://www.linkedin.com/oauth`, `aud` = client id, `sub` = the userinfo `sub`, `iat`/`exp` and an echoed `nonce`. Serve its JWKS at `/oauth/openid/jwks`, and add an `article.title` required check to mirror the real API (RC-03). Why: without it, H1 can't be on locally or in e2e.
- **H3. Send the nonce (gated).** In `amplify-api/handlers.bal:158`, when `adapter is linkedin:LinkedInAdapter`, use `adapter.authorizationUrlWithNonce(state.state, state.nonce)`. In `completeConnect`, pass `state.nonce` (the consumed state at `:177` has it) as `expectedNonce` to H1's `validate`. Only do this after a real LinkedIn app is seen to echo `nonce` in the ID token; LinkedIn doesn't document the parameter. Until then, pass `()`. Why: replay binding of the ID token to this browser flow.
- **H4. Wire key rotation.** Three pieces:
  - (a) In `amplify-domain/modules/connection/service.bal`, next to `openToken` (`:212`), add `resealToken(crypto:TokenCipher, StoredToken) returns StoredToken|error?`. It wraps `cipher.reseal(...)` with the same AAD and keeps `tokenId`, `issuedOn` and `expiresAt`.
  - (b) In `amplify-domain/modules/connection/repository.bal` (`PgTokenRepository`, around `:160-195`), add `updateSeal(StoredToken old, StoredToken resealed)`: `UPDATE connection.provider_token SET ciphertext = ?, nonce = ?, key_id = ? WHERE token_id = CAST(? AS uuid) AND issued_on = ? AND key_id = ?(old)`. The old `key_id` guard makes concurrent re-seals harmless.
  - (c) In `amplify-jobs`, add a maintenance step (beside `/maintenance/partitions`) that pages through `provider_token WHERE key_id <> ${cipher.activeKeyId()}` and re-seals each row. Optionally also re-seal opportunistically after a successful `openToken` at `amplify-jobs/handlers.bal:217`.

  Then update `token-and-oauth-notes.md` claim 2 and threat-model AMP-R2. Why: it lets a key be retired on compromise without waiting for partition drops.
- **H5. Pass the campaign title.** In `amplify-jobs/handlers.bal:223-230` (the `publishShare` call), add `targetTitle: c is () ? () : c.title`. Why: RC-03. Without it, `SHARE*` posts carry the generic `DEFAULT_ARTICLE_TITLE`.
- **H6. Version.** Either republish as `0.5.0` (no consumer change), or bump `amplify-common/Ballerina.toml` `version` to `0.6.0` together with `[[dependency]] version` in `amplify-api/Ballerina.toml:13`, `amplify-domain/Ballerina.toml:13` and `amplify-jobs/Ballerina.toml:13`, and update the "Current version" note in `amplify-common/CLAUDE.md`. Why: the package `CLAUDE.md` says to bump the version when the API changes, and the API grew additively.
- **H7. Docs.** In `architecture/security/token-and-oauth-notes.md`, update claim 2 (rotation API exists, wiring pending H4) and claim 6. Under the §2 gaps: PKCE isn't available to web clients (LinkedIn's native-client page), ID-token validation is available (pending H1), and LinkedIn's docs disagree on the issuer (RC-13). Mirror the same changes in `threat-model-phase1.md` rows 2.2 and 2.5.
- **H8. Behaviour notes for callers.** `googlechat:isPublicHttpsUrl` now refuses every IP-literal host, so a campaign image or avatar on a bare IP is left off the card. `types:awardReference` refuses parts with surrounding whitespace; current callers pass parsed or normalized values. `WebhookClient` refuses plain `http` unless the host is exactly `localhost`/`127.0.0.1` or `allowInsecureHttp` is set (the compose `chat-stub` already sets it).
