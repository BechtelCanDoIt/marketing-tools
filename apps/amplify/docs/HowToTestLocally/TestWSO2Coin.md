# Test WSO2 Coin locally

`projects/wso2-coin` is the WSO2 Coin programme. Despite what its `CLAUDE.md` says, it isn't one Ballerina app. The service Amplify will call later, **transaction-service, is Go**. No blockchain is involved at runtime: "wallets" are MySQL rows with `0x…` addresses, and balances are encrypted strings.

Surveyed on 2026-10-16. The balance-seeding helper in step 4 was run against the real `internal/crypto` package.

| Component | Path | Stack | Port |
| --- | --- | --- | --- |
| **transaction-service** | `operations/transaction-service` | Go 1.25 | 8080 (`PORT`) |
| Wallet backend | `apps/wso2-wallet/backend` | Go 1.25 | 8080, **hard-coded** |
| Wallet micro-app | `apps/wso2-wallet/microapp` | CRA React 18 | 3000 |
| O2C portal backend | `apps/o2c-portal/backend` | Ballerina 2201.12.7 | 9090 |
| O2C portal webapp | `apps/o2c-portal/webapp` | Vite + React + MUI | 3000 |
| QR portal (older) | `apps/qr-portal/{backend,webapp}` | Ballerina / Vite | 9090 / 3000 |

> `CLAUDE.md` is out of date. It describes only the portal, names the package `qr_portal` (o2c's is `o2c_portal`), lists a `gsheet` module that doesn't exist, has the wrong entry and store paths, and says to run `bal test` when there are no Ballerina tests. Trust the two Go READMEs and their `openapi.yaml` instead.

---

## 1. Prerequisites

- **Go 1.25+.** go1.25.1 is installed here.
- **MySQL 8+.** Docker `mysql:8.4` or your Homebrew MySQL.
- **Ballerina 2201.12.7** for the portals (`bal dist pull 2201.12.7 && bal dist use 2201.12.7`; this machine has 2201.13.3).
- **Node 22** for the webapps (no `engines` field anywhere).
- **`openssl`** to generate keys.
- There's no docker-compose, Dockerfile or Makefile. Everything runs on the host.

## 2. Database (`wso2_wallet`, shared by both Go services)

Order matters: `client_master_wallet` has a foreign key to `user_wallet`.

```bash
docker run -d --name coin-mysql -p 3307:3306 -e MYSQL_ROOT_PASSWORD=devpass mysql:8.4
mysql -h 127.0.0.1 -P 3307 -u root -pdevpass -e "CREATE DATABASE wso2_wallet"
mysql -h 127.0.0.1 -P 3307 -u root -pdevpass wso2_wallet < apps/wso2-wallet/backend/resources/schema.sql
mysql -h 127.0.0.1 -P 3307 -u root -pdevpass wso2_wallet < operations/transaction-service/resources/schema.sql
```

(Port 3307 avoids clashing with Novera's MySQL on 3306.) Skip `migration_add_reference.sql` and `migration_add_source.sql`. They're for existing deployments, and the schema already has those columns.

## 3. Config

```bash
openssl rand -base64 32        # → ENCRYPTION_KEY. Must be the SAME in both Go services
cp operations/transaction-service/.env.example operations/transaction-service/.env
cp apps/wso2-wallet/backend/.env.example        apps/wso2-wallet/backend/.env
```

**transaction-service `.env`**

| Key | Local value |
| --- | --- |
| `PORT` | **`8081`**, because the wallet backend is hard-wired to 8080 |
| `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` / `DB_NAME` | `127.0.0.1` / `3307` / `root` / `devpass` / `wso2_wallet` |
| `DB_TLS` | `false` (the default `preferred` expects TLS) |
| `ENCRYPTION_KEY` | The shared key above |
| `JWT_ALLOW_INSECURE` | `true` for local decode-only tokens (step 5). **Never in Choreo** |
| `CORS_ALLOWED_ORIGIN` | `http://localhost:3000` if a local UI calls it |

**wallet backend `.env`:** the same DB values, key and JWT settings. In addition:
- Set **`MAINTENANCE_MODE=false`** (the example ships `true`).
- Either set `INITIAL_COINS_ENABLED=false`, or point `INITIAL_COINS_FUNDING_WALLET` at a seeded wallet.
- There's no `DB_TLS` option here (hard-coded to `tls=preferred`), and a local MySQL without TLS is fine with that.

## 4. Seed a funded master wallet

Balances are AES-256-GCM ciphertext, bound to the address (`AAD = "o2c:balance:" + lower(address)`). A `NULL` `total_balance` breaks transfers, so **you can't seed a balance with plain SQL**. Generate the ciphertext with this throwaway helper. It has to sit inside the transaction-service module because `internal/` packages can't be imported from outside it. **Don't commit it.**

```go
// operations/transaction-service/cmd/seedbalance/main.go (local only)
package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"strings"

	"github.com/wso2/wso2-coin/operations/transaction-service/internal/crypto"
)

func main() {
	key, err := base64.StdEncoding.DecodeString(os.Getenv("ENCRYPTION_KEY"))
	if err != nil { panic(err) }
	enc, err := crypto.New(key)
	if err != nil { panic(err) }
	ct, err := enc.Encrypt(os.Args[2], "o2c:balance:"+strings.ToLower(os.Args[1]))
	if err != nil { panic(err) }
	fmt.Println(ct)
}
```

```bash
cd operations/transaction-service
export ENCRYPTION_KEY=<shared key>
MASTER=0x00000000000000000000000000000000000a11fe
RECIP=0x0000000000000000000000000000000000000b0b
MB=$(go run ./cmd/seedbalance $MASTER 1000.000000000)     # 9 decimal places
RB=$(go run ./cmd/seedbalance $RECIP  0.000000000)
mysql -h 127.0.0.1 -P 3307 -u root -pdevpass wso2_wallet <<SQL
INSERT INTO user_wallet (wallet_address, user_email, default_wallet, total_balance)
  VALUES ('$MASTER', 'amplify-master@wso2.com', TRUE, '$MB'),
         ('$RECIP',  'you@wso2.com',            TRUE, '$RB');
INSERT INTO client_master_wallet (client_id, wallet_address, use_case, client_name)
  VALUES ('amplify-local', '$MASTER', 'Amplify rewards (local)', 'Amplify');
SQL
rm -rf cmd/seedbalance
```

`client_id` has to match the `sub` of the token you call with (step 5).

## 5. Run and call it

```bash
(cd apps/wso2-wallet/backend        && go run ./cmd/server)   # :8080
(cd operations/transaction-service  && go run ./cmd/server)   # :8081
```

**A local token.** With `JWT_ALLOW_INSECURE=true` the service only decodes the JWT. It doesn't check the signature or expiry. The token is read from `X-Jwt-Assertion` first, then `Authorization: Bearer`, and its `sub` is the client ID.

```bash
b64() { printf '%s' "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '='; }
JWT="$(b64 '{"alg":"RS256","typ":"JWT"}').$(b64 '{"sub":"amplify-local","email":"you@wso2.com"}').local"

curl -s localhost:8081/wallets/master -H "X-Jwt-Assertion: $JWT" | jq .        # balance
curl -i -X POST localhost:8081/wallets/master/transfer -H "X-Jwt-Assertion: $JWT" \
  -H "Content-Type: application/json" -d "{\"toAddress\":\"$RECIP\",\"amount\":\"5\"}"   # → 201 + Location
```

The recipient must already exist in `user_wallet`. The wallet backend also needs an `email` claim, which the token above includes. Exact paths and payloads are in `operations/transaction-service/openapi.yaml`.

### Idempotency: important for Amplify's later Coin phase

- **`POST /wallets/master/transfer` is not idempotent.** The body is only `{toAddress, amount}` and the server makes up the reference. If you retry after a timeout, the coins can be paid **twice**.
- **`POST /payments` is idempotent.** It takes a caller-supplied `reference` and a `source` matching `^[A-Z][A-Z0-9_]{1,31}$` (so `AMPLIFY` works). Replaying with the same details returns **200**, and different details with the same reference return **409**. It's enabled only when a user-JWT JWKS or insecure mode is configured.

That changes what the L2 assumed (a transfer call with a caller reference): when Amplify's Coin issuer is built, it should use **`/payments`** with the ledger reference, not `/master/transfer`.

## 6. Tests

```bash
(cd operations/transaction-service && go test -race ./...)   # in-memory fakes, no DB needed
(cd apps/wso2-wallet/backend       && go test -race ./...)
(cd apps/wso2-wallet/microapp      && npm test)
(cd apps/o2c-portal/webapp         && npm run type-check && npm run lint)   # no test script
```

The Ballerina portals have no `tests/`, so `bal test` does nothing.

## 7. The portals (optional)

- **Backend:** `cp Config.toml.local Config.toml` and fill in `database.o2cDbConfig`, `authorization.authorizedRoles` (privilege codes 191/181/171, plus `o2cAdminRole`), the `people` and `conference` clients, and `transactions.transactionServiceEndpoint = "http://localhost:8081"` with a client-credentials config. Then `bal run` (:9090). It **decodes `x-jwt-assertion` without verifying it** and needs `email` and `groups` claims. Make a token with the `b64` helper above, adding `"groups":[…]`.
- **Webapp:** `cp public/config.js.local public/config.js`, set `ASGARDEO_BASE_URL`, `ASGARDEO_CLIENT_ID`, the redirects (`http://localhost:3000`) and `REACT_APP_BACKEND_BASE_URL`, then `npm install && npm run dev`. The browser sends `Authorization: Bearer`, but the backend wants `x-jwt-assertion`. Locally that needs a gateway (WSO2 APIM) or a header-rewriting proxy, as described in [TestPeopleOpsSuite.md](TestPeopleOpsSuite.md#webapp--backend-locally).
- Both portals use 9090 and both webapps use 3000, so run one pair at a time.
- `o2c-portal`'s `retryConfig` would be dangerous if it ever called the non-idempotent `/master/transfer`. Today it only calls search and wallet queries.

## 8. Gotchas

- Go 1.23+ needs `//go:debug x509negativeserial=1` to parse Asgardeo's JWKS. transaction-service already has it (`main.go:22`). Copy it into anything new that verifies Asgardeo tokens in Go.
- The wallet micro-app can't get a token outside the super-app's native bridge (it times out after 8 seconds), so test it inside the super-app or not at all.
- Changing `ENCRYPTION_KEY` makes every seeded balance unreadable. Reseed after you change it.
