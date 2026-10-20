# Code review: people directory, phase 1 UI, people-app service clients (2026-10-19)

Method: two `code-reviewer` passes (static read, WSO2 coding standards and engineering governance) over the open PRs: amplify-api / local tooling (this repo, marketing-tools #1 and wso2-amplify #4), One WSO2 Amplify UI (one-wso2 #1 merged on the fork, #2 open), people-app service clients (people-ops-suite #1). **No High findings.** Spot-checked by hand: R-A3, R-A1, R-B1, R-M1/R-A9.

## amplify-api and local tooling

| ID | Sev | Finding | Fix |
|---|---|---|---|
| M1 | Medium | One directory row with a null or missing `workEmail` makes the whole response "malformed" (`cloneWithType` on the array), so every viewer gets `UNAVAILABLE` (`outbound.bal` `DirectoryRecord`, `fetchDirectory`). | `string? workEmail`, skip and count bad rows in `indexDirectory` |
| M2 | Medium | No single-flight and no retry spacing on refresh: concurrent requests on an expired index each fetch the whole directory; during an outage every request waits for the timeout and logs a warning; 401/403/404 never open the breaker. The leaderboard looks the roster up before its 304 check, so revalidations pay too. Same root as the integration-boundary review's single fix. | Refresh off the request path (or "in flight / next attempt not before" under the lock), serve stale meanwhile, rate-limit the warning |
| M3 | Medium | `viewerTag` hashes team name and size, not membership: two people swapping teams keeps a stale `myTeam` behind a 304 until the standings change. | Hash the sorted member emails or an index version |
| M4 | Medium | The people directory isn't a declared Choreo connection in `.choreo/component.yaml` (plain config fields), while CLAUDE.md says egress goes through declared connections. | Add a `connectionReferences` entry (like `amplify-jobs`), or document it as manual config |
| M5 | Medium | No startup checks on the directory OAuth config: an `http://` token URL would send the client secret in clear outside local; a token URL without id/secret only fails at request time. | Require https unless `environment = local`; require all three auth values together |
| M6 | Medium | `scripts/e2e-local.sh` silently takes over whichever local user holds the mock LinkedIn member (removes and relinks their connection, gives them the e2e share); `psql` errors are swallowed; `LIMIT 1` without `ORDER BY`. | Require `E2E_TAKEOVER=1` (or print and confirm), stop swallowing errors, order the query |
| L1–L8 | Low | Stale-index warning on every request; a slow older fetch can overwrite a newer index; test gaps (auth client, non-200 paths, concurrent refresh, stub fixture order); `gateway.mjs` lacks the license header and a "never deploy" banner; `run.sh` hard-codes the network name and demo values; `proxy.mjs` logs emails and passes token values as argv (local only). | Fold into the M2 fix; small follow-ups |

Clean: isolation and locking in `directoryIndex`, configurables and gitignored secrets, descriptor/compose consistency, no PII in the new log lines, test port change.

## One WSO2 Amplify UI

| ID | Sev | Finding | Fix |
|---|---|---|---|
| A1 | Medium | One WSO2 sets `refetchOnMount: false` app-wide, so invalidating an unmounted Amplify query only marks it stale: save on New Post, go back to Current Posts, and the new post is missing until reload. | `refetchOnMount: "always"` on the Amplify campaign and share queries, or `refetchQueries` |
| A2 | Medium | Idempotency keys are minted inside `mutationFn`, so a double submit sends two keys and the server can't dedupe; the header comment overstates it. Enter in any New Post field runs "Save & share now". | One key per user intent (ref, reset on success); Enter = plain Save |
| A3 | Medium | `postUrnFromUrl` isn't anchored to LinkedIn: `https://evil.example/?x=urn:li:share:1` passes, and the raw URL becomes the `href` on every employee's Celebrate card. | Accept only `https://*.linkedin.com` (or omit `resourceUrl`); guard again in `linkedInPostUrl`; tests for hostile input |
| A4 | Medium | Open item D4: confirm the sign-in SDK never consumes `?code=&state=` on `/amplify/connect/callback` with real Asgardeo/ThunderID before the pilot. | Verify on dev |
| A5 | Low | `window.location.assign` on the API's `authorizationUrl` and `<img src>` on `imageUrl` take any scheme. | Require https (+ linkedin host for the redirect) |
| A6–A9 | Low | Invalidation keyed by a possibly unresolved `sub`; Update Post always rewrites `closesAt` and can't clear the image; only the first 50 posts are read; `indexPeople` crashes on a null `workEmail`; ThunderProvider relies on an undeclared SDK prop; CategoryPicker radio semantics; local-vs-UTC date edge. | Small fixes; the null-email guard first (it takes down Celebrate) |

Clean: `returnTo` open-redirect guard, StrictMode single-send, role gating fails closed, route guard, query keys scoped by `sub`, `rel="noopener noreferrer"`, no XSS path (text nodes), no server `detail` shown, 4xx no-retry.

Test gaps: AmplifyEditorRoute, `safeReturnTo`, the callback page, `amplifyError`, mutations, ThunderProvider.

## people-app service clients

| ID | Sev | Finding | Fix |
|---|---|---|---|
| B1 | Medium | "Service" is decided by *no email claim* + a listed `azp`. A user token also carries `azp`, so a user or service account with no email, signed in through a listed app, would read the whole directory with no role check. | Also require a client-credentials marker from the gateway JWT (e.g. `aut = APPLICATION`; confirm the claim on a real token); test an email-less token with groups |
| B2 | Low | Route matched by joined string: `/employees%2Fbasic-info` passes the interceptor (then 404s). Not a bypass, but looser than intended. | Compare segments: `path == ["employees", "basic-info"]` |
| B3 | Low | An unlisted email-less client gets 500 + an error stack, and no log names the client id. | 403 + a warning with the (truncated) claim value |
| B4 | Low | Successful service reads aren't logged. | Info log with the client id |
| B5 | Low | Inherited: the assertion isn't signature-checked (threat model AMP-R9); with this change a forged `{azp: <listed id>}` reads the directory without forging groups. Fail-closed default (empty list) untested; more edge-case tests. | Confirm gateway-only reachability; add the tests |

Clean: a token with an email never reaches the new branch; unlisted clients can't; the skip is limited to exactly `GET employees/basic-info`; other handlers still fail closed for a service caller; defaults fail closed.

## Suggested order

1. **B1** in the people-app PR before it goes upstream: it's the only finding that widens access in someone else's system.
2. **A3** and **M1 + A9** (null email): small, and each can break or abuse what every employee sees.
3. **M2 with M3** (refresh off the request path, ETag on membership): the one structural fix, shared with the integration-boundary review.
4. **A1, A2, M5, M6**, then the Lows and test gaps.

## Status (2026-10-19, later)

| ID | Status |
|---|---|
| B1 | **Fixed** (people-ops-suite PR): a service token must also be issued to an application (`aut = APPLICATION`, configurable) and carry no `email` or `groups`. Tests for an email-less user token with a listed `azp`, with `APPLICATION_USER`, with no marker and with `groups`. 7 tests; prototype 12/12 |
| B2 | **Fixed**: the route matches two segments exactly (encoded slash and extra segments get 403) |
| A3 | **Fixed** in both places: amplify-api only accepts post links on allowed origins (`campaignLinkOrigins`, LinkedIn by default; Compose adds the mock for local demos), domain-tested; One WSO2 checks the same list (`ONE_WSO2_AMPLIFY_POST_LINK_ORIGINS`) before sending, before rendering a card link, and before following the LinkedIn sign-in redirect (also covers A5's redirect half) |
| M1, A9 | **Fixed**: directory rows without a work email are skipped on both sides instead of breaking everything |
| M2, M3 | **Accepted**: teams change once or twice a year, so the 3-day TTL (`ROSTERCACHESECONDS`, now settable in Choreo) is enough; the refresh herd and the membership-blind ETag clear within the TTL |
| Others | Open |
