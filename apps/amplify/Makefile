# Local stack (plan M8a). Run from apps/amplify.
#   make up       build images, generate local/.env + dev JWT keys on first run, start the stack
#   make seed     rebuild and rerun Amplify DB Migrate (migrations + seeds, idempotent)
#   make e2e      end-to-end smoke test against the running stack (scripts/e2e-local.sh)
#   make down     stop and remove containers AND volumes
#   make check    descriptor drift + log hygiene (no PII/tokens/commentary in log calls) + transaction gate (R-13)
#   make test-all unit + IT (postgres:18, mock LinkedIn, DB down) + scheduler IT + e2e; cleans up after
#   make load-test k6 against the running stack: 1k employees / 50k ledger rows, p95 < 50 ms target
#   make up PROFILE=apim   also start WSO2 API Manager (pending the non-prod Asgardeo org)

COMPOSE := scripts/compose.sh $(if $(PROFILE),--profile $(PROFILE))

.PHONY: env up down seed e2e logs ps check test-all load-test

local/.env:
	@cp local/.env.example local/.env
	@for k in POSTGRES_PASSWORD AMPLIFY_API_DB_PASSWORD AMPLIFY_JOBS_DB_PASSWORD AMPLIFY_READONLY_DB_PASSWORD \
	          SCHEDULER_DB_PASSWORD LINKEDIN_CLIENT_SECRET; do \
	  v=$$(openssl rand -hex 16); sed -i.bak "s|^$$k=$$|$$k=$$v|" local/.env; done
	@v=$$(openssl rand -base64 32); sed -i.bak "s|^TOKEN_ENCRYPTION_KEY=$$|TOKEN_ENCRYPTION_KEY=$$v|" local/.env
	@rm -f local/.env.bak && chmod 600 local/.env
	@echo "Wrote local/.env with random local-only secrets."

local/dev-jwt/jwks.json:
	@local/dev-jwt/mint-dev-jwt.sh init

env: local/.env local/dev-jwt/jwks.json

up: env
	$(COMPOSE) up -d --build --wait

seed: env
	$(COMPOSE) run --rm --build amplify-db-migrate

e2e:
	scripts/e2e-local.sh

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps -a

down:
	$(COMPOSE) --profile apim down -v --remove-orphans

check:
	scripts/check-descriptors.sh
	scripts/check-logs-pii.sh
	scripts/check-transaction-gate.sh --self-test
	scripts/check-transaction-gate.sh

test-all:
	scripts/test-all.sh

load-test:
	scripts/load-test.sh
