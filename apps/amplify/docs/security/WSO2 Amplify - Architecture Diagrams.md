# WSO2 Amplify - Architecture Diagrams

Companion to the threat model `WSO2 Amplify Threat Model.docx` (version 0.4, 2026-10-26). Every diagram follows the code in `projects/marketing-tools/apps/amplify` as read on 2026-10-26. Where a fact could not be checked from the repository (real Choreo token claims, Choreo network behavior, what is deployed), the diagram says so.

## Notation

Participants carry a boundary tag. Arrows carry an interaction medium and a confidentiality class.

| Tag | Meaning |
|-----|---------|
| `[Untrusted]` | Untrusted entity (a browser on the internet, an anonymous caller) |
| `[B-IN]` | Internal boundary: components Amplify owns and runs |
| `[B-EX-CP]` | External component owned by WSO2 (Choreo gateway, people-app, Novera) |
| `[B-EX-EN]` | External entity (Asgardeo, LinkedIn, Google Chat) |
| `[B-EX-DP]` | External dependency (managed platform services) |
| `[M-NT]` | Network interaction (HTTP or HTTPS) |
| `[M-DB]` | Database interaction (TCP) |
| `[M-FS]` | File system interaction |
| `[M-IN]` | Internal interaction (container to container, same Project) |
| `[C-High]` | Highly confidential: tokens, secrets, member access tokens |
| `[C-Medium]` | Medium confidential: employee names, emails, points, campaign data |
| `[C-Low]` | Low confidential: settings, counters, health |

Two rules apply to every diagram. The dev JWT (ADR-023) exists only when `environment = local`, and `checkDevSwitch()` in `amplify-api/config.bal` stops startup otherwise. Traffic inside the Compose network and between Project components in Choreo is plain HTTP in the code and descriptors. Whether Choreo adds transport encryption between Project components is not verified here.

## Diagram 0: High-level system architecture

```mermaid
graph TB
    subgraph UNTRUST["Untrusted"]
        EMP["Employee browser<br/>[Untrusted]"]
        ROLES["Marketing / PO / SLT / Admin browser<br/>[Untrusted]"]
    end

    subgraph ONE["One WSO2 (owned by WSO2, separate repo)"]
        SPA["One WSO2 SPA, Amplify module<br/>[B-EX-CP]"]
    end

    subgraph IDP["Identity"]
        ASG["Asgardeo<br/>[B-EX-EN]"]
    end

    subgraph CELL["Amplify Choreo Project (the cell) [B-IN]"]
        PROXY["Choreo API proxy and gateway<br/>[B-EX-CP]"]
        API["amplify-api<br/>Ballerina, port 9090"]
        JOBS["amplify-jobs<br/>Ballerina, port 9091"]
        SCH["amplify-scheduler<br/>akorn/scheduler, port 8080<br/>no API auth"]
        DB[("PostgreSQL 18 amplify<br/>schemas per context<br/>managed by Choreo / Aiven")]
        SDB[("PostgreSQL scheduler<br/>own database and user")]
    end

    subgraph WSO2EXT["WSO2-owned services outside the cell"]
        PA["people-app directory<br/>GET /employees/basic-info<br/>[B-EX-CP]"]
        NOV["Novera / po-agent<br/>POST /internal/notifications<br/>[B-EX-CP]"]
        GW["Choreo gateways in front of<br/>people-app and Novera<br/>[B-EX-CP]"]
    end

    subgraph EXT["External entities"]
        LI["LinkedIn<br/>OAuth, userinfo, /rest/posts<br/>[B-EX-EN]"]
        GCW["Google Chat Club webhook<br/>[B-EX-EN]"]
        GCA["Google Chat API, DMs from Novera<br/>[B-EX-EN]"]
    end

    EMP -->|"HTTPS [M-NT] [C-Medium]"| SPA
    ROLES -->|"HTTPS [M-NT] [C-Medium]"| SPA
    SPA -.->|"OIDC sign-in [M-NT] [C-High]"| ASG
    SPA -->|"HTTPS, Asgardeo bearer token, Idempotency-Key<br/>[M-NT] [C-High]"| PROXY
    PROXY -->|"x-jwt-assertion backend JWT RS256<br/>[M-IN] [C-High]"| API
    API -->|"SQL, TLS verify-full by default<br/>[M-DB] [C-High]"| DB
    API -->|"schedule sync, HTTP, no auth<br/>[M-IN] [C-Low]"| SCH
    API -->|"POST /runs, 3 s timeout, HTTP, no auth<br/>[M-IN] [C-Low]"| JOBS
    SCH -->|"POST /runs and /maintenance/partitions<br/>HTTP, no auth [M-IN] [C-Low]"| JOBS
    SCH -->|"SQL, sslmode=require<br/>[M-DB] [C-Low]"| SDB
    JOBS -->|"SQL, TLS verify-full by default<br/>[M-DB] [C-High]"| DB
    API -->|"OAuth2 client credentials, GET directory<br/>HTTPS [M-NT] [C-Medium]"| GW
    GW --> PA
    JOBS -->|"OAuth2 client credentials, notification<br/>HTTPS [M-NT] [C-Medium]"| GW
    GW --> NOV
    NOV -->|"one DM card per user<br/>HTTPS [M-NT] [C-Medium]"| GCA
    JOBS -->|"POST /rest/posts, member token<br/>HTTPS [M-NT] [C-High]"| LI
    API -->|"code exchange, userinfo<br/>HTTPS [M-NT] [C-High]"| LI
    JOBS -->|"card, best effort when Novera is on<br/>HTTPS [M-NT] [C-Medium]"| GCW
    SPA -->|"photos and names, user's own token<br/>HTTPS [M-NT] [C-Medium]"| PA
```

## Diagram 1: Container architecture (local Compose stack)

```mermaid
graph LR
    subgraph HOST["Developer machine, host ports bound to 127.0.0.1"]
        BROWSER["Browser<br/>[Untrusted]"]
        P1["127.0.0.1:9090"]
        P2["127.0.0.1:19091"]
        P3["127.0.0.1:19092"]
        P4["127.0.0.1:9443 and 8243<br/>only with PROFILE=apim"]
    end

    subgraph NET["Compose network wso2-amplify_internal [B-IN], plain HTTP, no TLS"]
        API["amplify-api :9090<br/>environment=local<br/>UID 10014"]
        JOBS["amplify-jobs :9091<br/>no host port<br/>UID 10014"]
        SCH["scheduler :8080<br/>no host port<br/>UID 10014"]
        MIG["amplify-db-migrate<br/>one-shot, postgres admin user"]
        PG[("postgres :5432<br/>sslmode DISABLE")]
        SPG[("scheduler-db :5432")]
        RET["scheduler-retention<br/>one-shot SQL"]
        MLI["mock-linkedin :9090 and :9091"]
        CHS["chat-stub :9095"]
        PST["people-stub :9096"]
        APIM["apim WSO2 APIM 4.7.0<br/>optional profile"]
    end

    NOVM["local/novera-mock :3003<br/>run by hand with node<br/>binds 0.0.0.0"]
    PROTO["local/people-app-proto gateway :8080<br/>run by hand, unsigned assertions<br/>listens on all interfaces"]

    BROWSER -->|"HTTP [M-NT] [C-Medium] dev JWT"| P1
    BROWSER -->|"HTTP [M-NT] [C-High] OAuth page"| P2
    BROWSER -->|"HTTP [M-NT] [C-Medium]"| P3
    BROWSER -.->|"HTTPS [M-NT] [C-High]"| P4
    P1 --> API
    P2 --> MLI
    P3 --> PST
    P4 --> APIM
    APIM -.->|"HTTP [M-IN] [C-High]"| API
    API -->|"[M-DB] TCP 5432 [C-High]"| PG
    JOBS -->|"[M-DB] TCP 5432 [C-High]"| PG
    MIG -->|"[M-DB] TCP 5432 [C-High]"| PG
    SCH -->|"[M-DB] TCP 5432 [C-Low]"| SPG
    RET -->|"[M-DB] TCP 5432 [C-Low]"| SPG
    API -->|"HTTP [M-IN] [C-Low]"| SCH
    API -->|"HTTP [M-IN] [C-Low]"| JOBS
    SCH -->|"HTTP [M-IN] [C-Low]"| JOBS
    API -->|"HTTP [M-IN] [C-High] code exchange"| MLI
    JOBS -->|"HTTP [M-IN] [C-High] posts"| MLI
    JOBS -->|"HTTP [M-IN] [C-Medium]"| CHS
    API -->|"HTTP [M-IN] [C-Medium] directory"| PST
    JOBS -.->|"HTTP [M-NT] [C-Medium] only if NOVERA_ALLOW_INSECURE_HTTP"| NOVM
```

Choreo mapping: each Amplify component is a Choreo Service in one Project. `amplify-api` is published through the Choreo API proxy. `amplify-jobs` and `amplify-scheduler` declare Project visibility in `.choreo/component.yaml` and `workload.yaml` and have no proxy. Whether Choreo enforces that visibility in the deployed environment is not verified here.

## DFD 1: Sign-in and the shared API request path

```mermaid
sequenceDiagram
    autonumber
    participant U as Employee browser [Untrusted]
    participant SPA as One WSO2 SPA [B-EX-CP]
    participant IDP as Asgardeo [B-EX-EN]
    participant PX as Choreo API proxy [B-EX-CP]
    participant API as amplify-api [B-IN]
    participant DB as PostgreSQL amplify [B-IN]

    Note over U,IDP: Boundary: Untrust → Trust<br/>[M-NT] HTTPS<br/>[C-High] Access token with groups claim
    U->>SPA: Open Amplify module<br/>[M-NT] HTTPS [C-Medium]
    SPA->>IDP: OIDC sign-in, SDK obtains access token<br/>[M-NT] HTTPS [C-High]
    IDP-->>SPA: Access token (groups carry amplify_* roles)<br/>[M-NT] HTTPS [C-High]
    Note over SPA,API: Boundary: Untrust → Trust<br/>[M-NT] HTTPS bearer<br/>[C-High] Token and employee data
    SPA->>PX: API call with Authorization bearer and Idempotency-Key on POST<br/>[M-NT] HTTPS [C-High]
    PX->>PX: Validate token, scopes, rate limit (limits still open, P2)
    PX->>API: Forward with x-jwt-assertion backend JWT<br/>[M-IN] HTTP inside Project, transport not verified [C-High]
    API->>API: Verify RS256 against gateway JWKS, then exp, nbf, iss, aud, sub, email
    API->>API: Activity matrix, default deny, roles only from amplify_* groups
    alt token missing, malformed, bad signature, wrong role or unlisted route
        API->>DB: audit.audit_log outcome DENIED, no token or email values<br/>[M-DB] TCP 5432 [C-Medium]
        API-->>PX: 401 or 403 problem details with stable code
    else allowed
        API->>DB: Use case reads or writes, audit row on writes<br/>[M-DB] TCP 5432 [C-High]
        API-->>PX: 200 / 202 with X-Correlation-ID
    end
    PX-->>SPA: Response<br/>[M-NT] HTTPS [C-Medium]
    Note over API: JWKS unreachable and no cached keys gives 503, not 401.<br/>/health and /ready skip auth and are not published through the proxy.
```

## DFD 2: Connect a LinkedIn account

```mermaid
sequenceDiagram
    autonumber
    participant U as Employee browser [Untrusted]
    participant SPA as One WSO2 SPA [B-EX-CP]
    participant PX as Choreo API proxy [B-EX-CP]
    participant API as amplify-api [B-IN]
    participant LI as LinkedIn [B-EX-EN]
    participant DB as PostgreSQL amplify [B-IN]

    Note over U,LI: Boundary: Untrust → Trust → Untrust<br/>[M-NT] HTTPS<br/>[C-High] OAuth code, member access token
    SPA->>PX: POST /connections/linkedin/start<br/>[M-NT] HTTPS [C-High]
    PX->>API: forward [M-IN] [C-High]
    API->>DB: INSERT connection.oauth_state (64 hex chars, 10 min TTL, bound to employee)<br/>[M-DB] TCP 5432 [C-High]
    API-->>SPA: authorizationUrl (checked to be on LinkedIn's origin by the SPA)
    U->>LI: Consent page, scopes openid profile w_member_social<br/>[M-NT] HTTPS [C-High]
    LI-->>U: Redirect to One WSO2 callback with code and state<br/>[M-NT] HTTPS [C-High]
    SPA->>PX: POST /connections/linkedin/complete (code, state, redirectUri)<br/>[M-NT] HTTPS [C-High]
    PX->>API: forward [M-IN] [C-High]
    API->>API: Redirect URI must equal linkedinRedirectUri, else 422 before state is used
    API->>DB: DELETE oauth_state WHERE state and employee_id and not expired RETURNING (single use)<br/>[M-DB] TCP 5432 [C-High]
    API->>LI: Exchange code with client secret, GET /v2/userinfo<br/>[M-NT] HTTPS [C-High]
    LI-->>API: Access token, userinfo sub
    opt linkedinIdTokenValidation = true (default false)
        API->>LI: Fetch LinkedIn JWKS, verify RS256, iss, aud, exp, sub equals userinfo sub<br/>[M-NT] HTTPS [C-Low]
    end
    API->>API: Seal token with AES-256-GCM, AAD token_id|owner_id|provider, per-row key_id
    API->>DB: INSERT provider_token, UPDATE member_connection, audit, one transaction<br/>[M-DB] TCP 5432 [C-High]
    API-->>SPA: Connection status
    Note over API,DB: DELETE /connections/linkedin deletes the token row in the same transaction as removed_at
```

## DFD 3: Register a campaign and announce it (outbox, Novera, Club webhook)

```mermaid
sequenceDiagram
    autonumber
    participant U as Marketing or PO browser [Untrusted]
    participant PX as Choreo API proxy [B-EX-CP]
    participant API as amplify-api [B-IN]
    participant DB as PostgreSQL amplify [B-IN]
    participant SCH as amplify-scheduler [B-IN]
    participant JOBS as amplify-jobs [B-IN]
    participant GW as Choreo gateway for Novera [B-EX-CP]
    participant NOV as Novera po-agent [B-EX-CP]
    participant GCA as Google Chat API [B-EX-EN]
    participant GCW as Club webhook [B-EX-EN]

    Note over U,API: Boundary: Untrust → Trust<br/>[M-NT] HTTPS<br/>[C-Medium] Campaign copy, image URL
    U->>PX: POST /campaigns (optional shareNow=true)<br/>[M-NT] HTTPS [C-Medium]
    PX->>API: forward, matrix allows amplify_marketing or amplify_po<br/>[M-IN] [C-Medium]
    API->>DB: campaign row, CampaignRegistered outbox row, audit row, one transaction<br/>[M-DB] TCP 5432 [C-Medium]
    opt shareNow
        API->>JOBS: POST /runs, 3 s timeout, X-Correlation-ID<br/>[M-IN] HTTP, no auth [C-Low]
    end
    Note over SCH,JOBS: Boundary: Trust → Trust<br/>[M-IN] HTTP, no authentication (ADR-026)<br/>[C-Low] Empty body
    SCH->>JOBS: POST /runs on schedule (default every 5 min)<br/>[M-IN] HTTP, no auth [C-Low]
    JOBS->>DB: Claim outbox rows FOR UPDATE SKIP LOCKED, 300 s lease<br/>[M-DB] TCP 5432 [C-Medium]
    JOBS->>JOBS: Build notification: title, summary, image (public https only), button to Celebrate with ?share=campaignId
    Note over JOBS,NOV: Boundary: Trust → Trust (WSO2 owned)<br/>[M-NT] HTTPS, OAuth2 client credentials<br/>[C-Medium] Campaign copy, no employee data
    JOBS->>GW: POST /internal/notifications, no idempotency key, X-Correlation-ID<br/>[M-NT] HTTPS [C-Medium]
    GW->>NOV: Forward after subscription check
    NOV-->>JOBS: 202 accepted (before anything is sent)
    NOV->>GCA: One card per DM, about 20 per second<br/>[M-NT] HTTPS [C-Medium]
    JOBS->>DB: announcement status SENT on 202, outbox row done<br/>[M-DB] TCP 5432 [C-Low]
    opt Club webhook configured (amplifyOnWebhook)
        JOBS->>GCW: Card, best effort, never retried when Novera accepted<br/>[M-NT] HTTPS, secret URL [C-Medium]
    end
    Note over JOBS,DB: 503 or 429 from Novera, or no response: retry through the outbox with backoff.<br/>Other 4xx: FAILED. A lost write after the 202 sends the card to every DM again.
```

## DFD 4: Share a campaign as a repost

```mermaid
sequenceDiagram
    autonumber
    participant U as Employee browser [Untrusted]
    participant PX as Choreo API proxy [B-EX-CP]
    participant API as amplify-api [B-IN]
    participant DB as PostgreSQL amplify [B-IN]
    participant JOBS as amplify-jobs [B-IN]
    participant LI as LinkedIn [B-EX-EN]

    Note over U,API: Boundary: Untrust → Trust<br/>[M-NT] HTTPS<br/>[C-Medium] Optional commentary text
    U->>PX: POST /campaigns/{id}/shares (kind REPOST or REPOST_COMMENTARY)<br/>[M-NT] HTTPS [C-Medium]
    PX->>API: forward [M-IN] [C-Medium]
    API->>API: employeeId from token, campaign OPEN, connection ACTIVE or EXPIRING, sharing.enabled
    API->>DB: share_request, RepostRequested outbox row, audit, one transaction<br/>[M-DB] TCP 5432 [C-Medium]
    API-->>U: 202 Accepted
    Note over JOBS,LI: Boundary: Trust → Untrust<br/>[M-NT] HTTPS<br/>[C-High] Decrypted member access token
    JOBS->>DB: Claim outbox row, load connection and sealed token<br/>[M-DB] TCP 5432 [C-High]
    JOBS->>JOBS: Decrypt token in memory, re-check published_at IS NULL, per-run 50 and per-day 1000 ceilings
    JOBS->>LI: POST /rest/posts with reshareContext.parent, LinkedIn-Version header<br/>[M-NT] HTTPS bearer [C-High]
    LI-->>JOBS: 201 and reshare URN, or 401, 403, 422, 429, 5xx
    JOBS->>DB: engagement, ledger row HELD, recognition standing, commentary set to null, one transaction<br/>[M-DB] TCP 5432 [C-Medium]
    Note over JOBS,LI: 401 revokes the connection (NEEDS_RECONNECT).<br/>429, 5xx and timeouts retry through the outbox with backoff, 8 attempts.<br/>A lost write after LinkedIn accepted can post twice (ADR-025 item 5).
```

## DFD 5: External share review and PO point corrections

```mermaid
sequenceDiagram
    autonumber
    participant E as Employee browser [Untrusted]
    participant P as PO browser [Untrusted]
    participant PX as Choreo API proxy [B-EX-CP]
    participant API as amplify-api [B-IN]
    participant DB as PostgreSQL amplify [B-IN]

    Note over E,API: Boundary: Untrust → Trust<br/>[M-NT] HTTPS<br/>[C-Medium] Evidence URL naming the employee
    E->>PX: POST /external-shares (evidence URL, certify)<br/>[M-NT] HTTPS [C-Medium]
    PX->>API: forward [M-IN] [C-Medium]
    API->>API: parseEvidenceUrl: https only, no credentials, no IP literal, normalize, never fetched
    API->>DB: INSERT external_share UNIQUE (evidence_url, action), outbox, audit<br/>[M-DB] TCP 5432 [C-Medium]
    P->>PX: POST /po/external-shares/{id}/approve or reject or amplified<br/>[M-NT] HTTPS [C-Medium]
    PX->>API: forward, matrix allows amplify_po only [M-IN] [C-Medium]
    API->>API: PENDING only, optimistic lock, claimant cannot decide own claim (SELF_REVIEW)
    API->>DB: decision, ledger award, recognition standing, audit with before and after, one transaction<br/>[M-DB] TCP 5432 [C-Medium]
    P->>PX: POST /po/points/adjustments or /po/points/{reference}/reverse (reason required)<br/>[M-NT] HTTPS [C-Medium]
    PX->>API: forward, amplify_po only [M-IN] [C-Medium]
    API->>API: Target employee must not be the caller (SELF_REVIEW, fixed 2026-10-26)
    API->>DB: Append ADJ- or REV- ledger row, recognition update, audit<br/>[M-DB] TCP 5432 [C-Medium]
    Note over API,DB: Ledger columns points, employee_id and reference are immutable by column-level grants.
```

## DFD 6: Admin settings, scheduler sync, run and maintenance

```mermaid
sequenceDiagram
    autonumber
    participant A as Admin browser [Untrusted]
    participant PX as Choreo API proxy [B-EX-CP]
    participant API as amplify-api [B-IN]
    participant DB as PostgreSQL amplify [B-IN]
    participant SCH as amplify-scheduler [B-IN]
    participant SDB as PostgreSQL scheduler [B-IN]
    participant JOBS as amplify-jobs [B-IN]

    Note over A,API: Boundary: Untrust → Trust<br/>[M-NT] HTTPS<br/>[C-Low] Settings, kill switches, schedule
    A->>PX: PUT /admin/settings or POST /admin/scheduler/sync<br/>[M-NT] HTTPS [C-Low]
    PX->>API: forward, amplify_admin only [M-IN] [C-Low]
    API->>API: Whitelist, ranges, schedule grammar, @every at least 60 s, optimistic lock
    API->>DB: config.app_setting, audit SettingChanged<br/>[M-DB] TCP 5432 [C-Low]
    Note over API,SCH: Boundary: Trust → Trust<br/>[M-IN] HTTP, no authentication (ADR-026)<br/>[C-Low] Job definitions, empty bodies
    API->>SCH: Upsert jobs amplify-run and amplify-maintenance-partitions<br/>[M-IN] HTTP, no auth [C-Low]
    SCH->>SDB: Job definitions and history (30 day trigger purge)<br/>[M-DB] TCP 5432, sslmode=require [C-Low]
    API->>DB: audit SchedulerSynced<br/>[M-DB] TCP 5432 [C-Low]
    SCH->>JOBS: POST /runs (deadline 300 s, jobs budget 240 s)<br/>[M-IN] HTTP, no auth [C-Low]
    JOBS->>DB: Outbox drain, LinkedIn, Novera, Chat, scoring under session advisory lock<br/>[M-DB] TCP 5432 [C-High]
    JOBS-->>SCH: 200 run log, or 202 SKIPPED when a run is in progress
    SCH->>JOBS: POST /maintenance/partitions (daily 02:00 UTC)<br/>[M-IN] HTTP, no auth [C-Low]
    JOBS->>DB: Partition upkeep, outbox and idempotency purge, token key re-seal<br/>[M-DB] TCP 5432 [C-High]
    Note over JOBS: POST /maintenance/rebuild-recognition is a third unauthenticated mutation.<br/>It rebuilds every recognition table from the ledger.
```

## DFD 7: People directory read, open leaderboards, headcount and weekly top three

```mermaid
sequenceDiagram
    autonumber
    participant U as Employee browser [Untrusted]
    participant PX as Choreo API proxy [B-EX-CP]
    participant API as amplify-api [B-IN]
    participant DB as PostgreSQL amplify [B-IN]
    participant GW as Choreo gateway for people-app [B-EX-CP]
    participant PA as people-app [B-EX-CP]

    Note over U,API: Boundary: Untrust → Trust<br/>[M-NT] HTTPS<br/>[C-Medium] Names, emails, points of every employee
    U->>PX: GET /leaderboard/people, /leaderboard/groups, /headcount, /leaderboard/top<br/>[M-NT] HTTPS [C-Medium]
    PX->>API: forward, matrix allows every signed-in employee [M-IN] [C-Medium]
    alt directory index or headcount cache expired (3 days and 7 days)
        Note over API,PA: Boundary: Trust → Trust (WSO2 owned)<br/>[M-NT] HTTPS, OAuth2 client credentials<br/>[C-Medium] Whole directory, more columns than Amplify reads
        API->>GW: Token request, then GET /employees/basic-info, X-Correlation-ID, 10 s timeout<br/>[M-NT] HTTPS [C-Medium]
        GW->>PA: x-jwt-assertion with azp and aut claims (claim names not confirmed on a real token)
        PA->>PA: jwt:decode only, signature not verified. Admit if aut = APPLICATION and azp is listed
        PA-->>API: Every current employee: email, team, sub-team, BU, house, photo, manager email, start date
        API->>API: Keep five fields in memory only, never in the database or logs
    end
    API->>DB: standing and ledger reads, weekly totals cached 2 hours per replica<br/>[M-DB] TCP 5432 [C-Medium]
    API-->>PX: Ranks, points, names, emails, ETag per viewer, Cache-Control private
    PX-->>U: Response<br/>[M-NT] HTTPS [C-Medium]
    Note over U,PA: The SPA also reads people-app directly with the user's own token for photos and names.<br/>Directory down and never loaded: group boards and headcount answer 503, company board still works.
```

## DFD 8: Role-gated dashboards, person board and CSV export

```mermaid
sequenceDiagram
    autonumber
    participant R as PO, Marketing, SLT or Admin browser [Untrusted]
    participant PX as Choreo API proxy [B-EX-CP]
    participant API as amplify-api [B-IN]
    participant DB as PostgreSQL amplify [B-IN]

    Note over R,API: Boundary: Untrust → Trust<br/>[M-NT] HTTPS<br/>[C-Medium] Aggregates, then names and emails on person and export routes
    R->>PX: GET /dashboards/glance, operations, campaigns, participation, scorecard<br/>[M-NT] HTTPS [C-Medium]
    PX->>API: forward [M-IN] [C-Medium]
    API->>API: Matrix: DASHBOARD_READERS only, plain employee gets 403 ROLE_NOT_PERMITTED (audited)
    API->>DB: One REPEATABLE READ, READ ONLY snapshot, about 15 statements, cached 60 s<br/>[M-DB] TCP 5432 [C-Medium]
    API-->>R: Board JSON
    R->>PX: GET /dashboards/people/{employeeId}<br/>[M-NT] HTTPS [C-Medium]
    PX->>API: forward, DASHBOARD_READERS [M-IN] [C-Medium]
    API->>DB: Person identity and their reposts (cut at 200 posts)<br/>[M-DB] TCP 5432 [C-Medium]
    API-->>R: Display name, email, per-post counts, points
    R->>PX: GET /dashboards/export?from=YYYY-MM-DD&to=YYYY-MM-DD (at most 366 days)<br/>[M-NT] HTTPS [C-Medium]
    PX->>API: forward, DASHBOARD_READERS [M-IN] [C-Medium]
    API->>DB: Export query LIMIT 200000, no truncation marker<br/>[M-DB] TCP 5432 [C-Medium]
    API->>API: Build whole CSV in memory, leading quote on = + - @ tab CR, quote and double embedded quotes
    API-->>R: text/csv attachment with employee_id, employee_name, employee_email
    Note over API: No audit row and no log line for a successful person board read or export.<br/>Only denials are audited.
```

## DFD 9: Local stack sign-in with the dev JWT (environment = local only)

```mermaid
sequenceDiagram
    autonumber
    participant D as Developer browser or script [Untrusted]
    participant LP as local/one-wso2-proxy [B-IN]
    participant API as amplify-api [B-IN]
    participant PG as postgres [B-IN]

    Note over D,API: Boundary: Untrust → Trust, local machine only<br/>[M-NT] HTTP on 127.0.0.1<br/>[C-Medium] Test users, no real PII
    D->>LP: Request to the dev proxy (binds 127.0.0.1), role chosen by the developer<br/>[M-NT] HTTP [C-Medium]
    LP->>API: x-jwt-assertion signed with local/dev-jwt private key (gitignored, generated on first make up)<br/>[M-IN] HTTP [C-Medium]
    API->>API: checkDevSwitch passed: environment = local, devIssuer set and different from gatewayIssuer
    API->>API: iss equals devIssuer: verify only against dev keys. No kid: try every dev key
    API->>PG: Queries as amplify_api, sslmode DISABLE<br/>[M-DB] TCP 5432 [C-Medium]
    API-->>LP: Response with X-Correlation-ID
    Note over API: In Choreo environment is dev or prod, devLocalJwtEnabled is absent from every descriptor,<br/>and scripts/check-descriptors.sh fails make check if it appears.
```

## Summary of boundary crossings

| DFD | Boundary Crossing | Medium | Confidentiality |
|-----|-------------------|--------|-----------------|
| Diagram 0: High-level architecture | All boundaries | [M-NT], [M-IN], [M-DB] | [C-High] tokens and secrets, [C-Medium] employee data |
| Diagram 1: Container architecture (local) | Untrust → Trust (loopback), Trust → Trust | [M-NT], [M-IN], [M-DB] | [C-Medium] test data, [C-High] dev tokens |
| DFD 1: Sign-in and API request path | Untrust → Trust, Trust → Trust | [M-NT] HTTPS, [M-IN], [M-DB] | [C-High] access token and backend JWT |
| DFD 2: Connect LinkedIn | Untrust → Trust, Trust → Untrust | [M-NT] HTTPS, [M-DB] | [C-High] OAuth code and member token |
| DFD 3: Register campaign and announce | Untrust → Trust, Trust → Trust, Trust → Untrust | [M-NT] HTTPS, [M-IN] HTTP, [M-DB] | [C-Medium] campaign copy, [C-High] Novera client secret |
| DFD 4: Share as repost | Untrust → Trust, Trust → Untrust | [M-NT] HTTPS, [M-DB] | [C-High] decrypted member token |
| DFD 5: External share and PO corrections | Untrust → Trust | [M-NT] HTTPS, [M-DB] | [C-Medium] evidence URLs, points, reasons |
| DFD 6: Settings, scheduler, run, maintenance | Untrust → Trust, Trust → Trust | [M-NT] HTTPS, [M-IN] HTTP no auth, [M-DB] | [C-Low] settings, [C-High] tokens handled in jobs |
| DFD 7: Directory read and open leaderboards | Untrust → Trust, Trust → Trust (WSO2 owned) | [M-NT] HTTPS, [M-DB] | [C-Medium] names, emails, points |
| DFD 8: Dashboards, person board, export | Untrust → Trust | [M-NT] HTTPS, [M-DB] | [C-Medium] names and emails in bulk |
| DFD 9: Local dev JWT | Untrust → Trust (loopback only) | [M-NT] HTTP, [M-IN], [M-DB] | [C-Medium] test data |
