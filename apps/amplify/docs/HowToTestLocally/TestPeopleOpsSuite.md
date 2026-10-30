# Test People Ops Suite locally

`projects/people-ops-suite` holds WSO2's People Ops apps: Ballerina backends, React webapps and scheduled jobs. Each app is deployed on Choreo. Amplify borrows two patterns from here: the scheduled task (`people-scheduler`, `sabbatical-reminder`) and the handler → service → repository layout.

Surveyed on 2026-10-16. Paths below are relative to `projects/people-ops-suite/apps/`.

| App | Components | Ballerina | Notes |
| --- | --- | --- | --- |
| **people-app** | backend (9090), webapp (CRA), microapp (Vite, 3000), **people-scheduler** | 2201.12.7 | The HRIS. Modules: authorization, database, email, qr, scim (Asgardeo), promotion (2nd DB), wso2_coin |
| **leave-app** | backend (9090), webapp (Vite, 3000), **sabbatical-reminder** | backend **2201.9.8**, reminder 2201.12.7 | Leave and sabbatical. Calls HR Entity GraphQL, email, calendar. The only real local-setup README |
| menu-app | backend (9090), webapp | **2201.10.4** | Google Sheets menu, dinner-on-demand on MySQL |
| visitor-app | backend (9090), webapp, micro-app, active-visit-reminder | 2201.12.7 | Visitors and visits |
| careers-app | backend (8080, configurable), webapp (Vite, Vitest) | 2201.12.7 | Public jobs API. Best test setup, no MySQL |

---

## 1. Prerequisites

- **Ballerina, three versions.** Switch per component:
  ```bash
  bal dist pull 2201.12.7 && bal dist pull 2201.10.4 && bal dist pull 2201.9.8
  bal dist use 2201.12.7          # check the component's Ballerina.toml `distribution` first
  ```
  This machine has 2201.13.3, which is newer than every pin. Builds may work on it, but match the pin before a PR.
- **Node 22.** Vite 7 needs 20.19+ or 22.12+. leave-app's README says 18+, which is out of date.
- **MySQL 8+.** `dod.sql` uses the MySQL 8-only collation `utf8mb4_0900_ai_ci`.
- **The `mysql` CLI.** people-app's SQL uses `DELIMITER //`, which GUI and JDBC tools mangle.
- No Dockerfiles, no docker-compose and no `.choreo` files. leave-app has OpenChoreo `workload.yaml` files (port 9090).

## 2. Database

```bash
docker run -d --name pops-mysql -p 3308:3306 -e MYSQL_ROOT_PASSWORD=devpass mysql:8.4
```

| App | Script | Notes |
| --- | --- | --- |
| people-app | `people-app/backend/resources/people_app_creation.sql` | Create the database yourself first. 38 tables and 41 triggers. **Starts with `DROP TABLE IF EXISTS`**, so never point it at shared data. Seeds `house` and the leadership groups. Already includes the latest schema; the `_update_v1.x` files are only for upgrades. The scheduler shares this DB. A second DB is needed for `promotion` |
| leave-app | — | **No base schema in the repo**, only `leave_app_update_v1.1.1.sql`. Ask the team for a schema dump |
| menu-app | `menu-app/backend/resources/dod.sql` | Creates `dinner_on_demand` itself |
| visitor-app | `visitor-app/backend/resources/database.sql` | Create the database first |

```bash
mysql -h 127.0.0.1 -P 3308 -u root -pdevpass -e "CREATE DATABASE people_ops"
mysql -h 127.0.0.1 -P 3308 -u root -pdevpass people_ops < people-app/backend/resources/people_app_creation.sql
```

To call people-app's `/user-info`, your test email must exist in the employee table. Insert one row for yourself.

## 3. Backends

```bash
cd people-app/backend
cp Config.toml.local Config.toml      # git-ignored
bal build && bal run                  # :9090
```

- **Fill in every value.** The people-app sample has blanks like `port = `, which isn't valid TOML, so the service won't start. Keep `promotionDbConfig.maxConnectionLifeTime` below MySQL's `wait_timeout`.
- **Role names must be set.** `checkPermissions` refuses roles configured as `""`, so blank role names lock everyone out.
- **External clients** (SCIM, email, QR, wso2_coin, HR Entity, Sheets, calendar, SMS) each need `tokenUrl`, `clientId` and `clientSecret`. There are no stubs, and a client that fails to initialize can stop startup. Use placeholder URLs or a mock server.
- **No template for these two:** leave-app's full `Config.toml` is inline in `leave-app/README.md` (around lines 33–110). menu-app's README points to a `config.local.toml` that doesn't exist; the keys are `databaseConfig`, the three `*SheetClientConfig` entries, `clientAuthConfig`, `retryConfig`, `peopleEndpoint` and `authorizedRoles`.

### Call a backend with a local token

The people, leave, menu and visitor backends read **`x-jwt-assertion`** and only **decode** it (`jwt:decode`, with no signature, expiry or issuer check). They then map the `email` and `groups` claims onto the configured role names.

```bash
b64() { printf '%s' "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '='; }
JWT="$(b64 '{"alg":"RS256","typ":"JWT"}').$(b64 '{"email":"you@wso2.com","groups":["<EMPLOYEE_ROLE value from Config.toml>"]}').local"
curl -s localhost:9090/user-info -H "x-jwt-assertion: $JWT" | jq .
```

A missing header returns **500**, not 401.

careers-app is the exception. It reads `Authorization: Bearer` and fully validates the token against the JWKS, issuer and audience in its config. Its job list, org structure, job detail and apply routes are open to guests.

> Amplify note: the decode-only interceptor is the pattern the L2 says **not** to copy. amplify-api must verify the signature (or sit behind APIM / the Choreo API Proxy).

## 4. Schedulers

These are plain Ballerina `main()` programs with no listener. One `bal run` is one cron firing.

```bash
cd people-app/people-scheduler && cp Config.toml.local Config.toml && bal run
```

- **people-scheduler** runs leaver transitions, scheduled changes and joiner activation one after another, and returns an error if any of them fails. It **writes to the people DB**, so run it against your local copy only.
- **sabbatical-reminder:** apply `leave_app_update_v1.1.1.sql` first, and keep **`isDebug = true`**. Mail then goes only to `debugRecipients`, and reminders aren't marked as sent.
- **active-visit-reminder** has no template. It needs `visitorServiceEndpoint`, `emailServiceEndpoint`, two `clientAuthConfig` blocks, `fromEmailAddress` and `adminEmailList`, and it calls the visitor backend over HTTP.

## 5. Webapps

```bash
cd leave-app/webapp
cp public/config.js.local public/config.js     # leave-app: copy the example from leave-app/README.md:124-136
npm install && npm run dev                     # :3000
```

- Config is runtime `window.config` (`/config.js`). The keys are `APP_NAME`, `APP_DOMAIN`, `ASGARDEO_BASE_URL`, `ASGARDEO_CLIENT_ID`, `ASGARDEO_REVOKE_ENDPOINT`, `AUTH_SIGN_IN_REDIRECT_URL`, `AUTH_SIGN_OUT_REDIRECT_URL` and `REACT_APP_BACKEND_BASE_URL`. The people microapp uses `CLIENT_ID`, `SIGN_IN_REDIRECT_URL`, `IS_MICROAPP` and `BACKEND_BASE_URL` instead.
- You need a non-prod Asgardeo SPA app with `http://localhost:3000` as a redirect URL.
- people-app/webapp's README says to create a `.env`, but the code only reads `window.config`. It has no lockfile, and `CLAUDE.md` uses `yarn`.
- **Every UI wants port 3000**, and so do One WSO2 and Novera. Run one at a time, or override the port and add that port to the Asgardeo redirects.
- Microapps get their token from the super-app's native bridge, so they can't sign in on their own in a browser.

### Webapp → backend locally

**This doesn't work out of the box.** The webapps send `Authorization: Bearer <idToken>`, the backends expect `x-jwt-assertion` (which the Choreo gateway normally injects), and the backends have no CORS. You can fix it two ways:

1. **Local WSO2 API Manager** (the team's local-gateway choice), with non-prod Asgardeo as its key manager. Publish the backend as an API, and APIM adds `x-jwt-assertion`. This is the closest match to Choreo.
2. **A dev proxy in Vite** that copies the bearer token into `x-jwt-assertion` and keeps everything same-origin:
   ```ts
   // vite.config.ts (local only)
   server: { proxy: { "/api": {
     target: "http://localhost:9090", changeOrigin: true,
     rewrite: (p) => p.replace(/^\/api/, ""),
     configure: (proxy) => proxy.on("proxyReq", (req, incoming) => {
       const auth = incoming.headers.authorization;
       if (auth?.startsWith("Bearer ")) req.setHeader("x-jwt-assertion", auth.slice(7));
     }),
   } } }
   ```
   Then set `REACT_APP_BACKEND_BASE_URL: "http://localhost:3000/api"`. The CRA apps (people webapp, visitor) would need `src/setupProxy.js` to do the same.

## 6. Tests

| Component | Command | Notes |
| --- | --- | --- |
| careers-app backend | `bal test` | `tests/` plus per-module tests, each with a dummy `Config.toml` (port 9099, mocks on 9098). Its `allowedOrigins` is `localhost:5173`, but Vite runs on 3000 |
| people-app backend | `bal test` | 7 files in `modules/database/tests`. The DB client is created at module load, so **a reachable MySQL and a filled-in `Config.toml` are probably needed** |
| other Ballerina components | — | No tests and no `@test:Mock` anywhere |
| Vite webapps | `npm run lint && npm run type-check` (careers: `npm test`) | |
| CRA webapps | `npm test` (Jest) | people-app/webapp has 6 test files |

## 7. Gotchas

- Three Ballerina versions are in use, and leave-app's backend (2201.9.8) and reminder (2201.12.7) differ.
- leave-app has no base schema. menu-app's config template is missing.
- `people_app_creation.sql` drops tables, needs the `mysql` CLI, and assumes the database already exists.
- `visitor-app/micro-app/env local` has a space in the filename. It's probably meant to be `.env.local`.
