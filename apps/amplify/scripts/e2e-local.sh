#!/usr/bin/env bash
# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Local end-to-end smoke test (plan M8a) against `make up`. DEV-ONLY: uses ADR-023 dev JWTs.
#   register campaign -> scheduler fires amplify-run -> jobs POST /runs -> chat-stub got the card
#   -> connect LinkedIn via mock OAuth (scripted redirect) -> share -> run -> points -> leaderboard
# Needs: curl, jq, docker compose. Exits non-zero on the first failed step.
set -euo pipefail
cd "$(dirname "$0")/.."

API="${API:-http://localhost:9090}"
COMPOSE=(docker compose --env-file local/.env)
MINT=local/dev-jwt/mint-dev-jwt.sh
RUN_ID="$(date +%s)"
# One fixed employee: the mock signs every authorization in as the same LinkedIn member, and a member URN
# belongs to one employee (B13). Reruns disconnect first, so the OAuth leg runs every time.
EMP_SUB="e2e-employee"
EMP_EMAIL="e2e.employee@wso2.com"
# On a stack someone has been using, the mock member may already belong to another employee, and it stays
# theirs even after they disconnect (B13: unique member_urn, removed rows included). Then this run acts as
# that employee: relinking your own member is allowed. Their shares and points get the e2e post's activity.
holder=$("${COMPOSE[@]}" exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d amplify -At -F "|" -c "
  SELECT c.employee_id, e.email FROM connection.member_connection c JOIN identity.employee e USING (employee_id)
  WHERE c.employee_id <> '"'e2e-employee'"' LIMIT 1"' 2>/dev/null || true)
if [[ -n "$holder" ]]; then
  IFS='|' read -r EMP_SUB EMP_EMAIL <<<"$holder"
  echo "note: the mock LinkedIn member belongs to $EMP_EMAIL; running the employee steps as them"
fi

ADMIN_JWT="$($MINT token e2e-admin admin.e2e@wso2.com amplify_admin amplify_marketing)"
EMP_JWT="$($MINT token "$EMP_SUB" "$EMP_EMAIL")"

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# call <jwt> <method> <path> [json body] -> body on stdout; fails on non-2xx
call() {
  local jwt="$1" method="$2" path="$3" body="${4:-}" out code
  out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$API$path" \
    -H "x-jwt-assertion: $jwt" -H 'Content-Type: application/json' \
    -H "X-Correlation-ID: e2e-${RUN_ID}" ${body:+--data "$body"})
  if [[ "$code" != 2* ]]; then cat "$out" >&2; rm -f "$out"; fail "$method $path -> $code"; fi
  cat "$out"; rm -f "$out"
}
# wait_for <seconds> <description> <command...>: retry until the command succeeds
wait_for() {
  local secs="$1" what="$2"; shift 2
  for ((i = 0; i < secs; i += 2)); do
    if "$@" >/dev/null 2>&1; then echo "ok: $what"; return 0; fi
    sleep 2
  done
  fail "timed out after ${secs}s waiting for: $what"
}
internal_get() { "${COMPOSE[@]}" exec -T "$1" wget -qO- "$2"; }

step "health"
curl -fsS "$API/ready" | jq -e '.status == "UP"' >/dev/null || fail "amplify-api not ready"

step "run.schedule -> @every 10s (pushed to the scheduler)"
version=$(call "$ADMIN_JWT" GET /admin/settings | jq -r '.settings[] | select(.key == "run.schedule") | .version')
call "$ADMIN_JWT" PUT /admin/settings \
  "{\"changes\":[{\"key\":\"run.schedule\",\"value\":\"@every 10s\",\"version\":$version}]}" \
  | jq -e '.schedulerSync == "SYNCED" or .schedulerSync.status == "SYNCED"' >/dev/null \
  || fail "scheduler sync did not report SYNCED"

step "register campaign"
TITLE="E2E campaign ${RUN_ID}"
campaign=$(call "$ADMIN_JWT" POST /campaigns "$(jq -nc --arg t "$TITLE" --arg u "urn:li:share:${RUN_ID}" '{
  resourceUrn: $u, ownerUrn: "urn:li:organization:1477", title: $t, summary: "Local e2e smoke test",
  resourceUrl: "https://www.linkedin.com/feed/update/\($u)", categoryCode: "PRODUCT", tags: ["e2e"]}')")
CAMPAIGN_ID=$(jq -r '.campaign.id // .id' <<<"$campaign")
echo "campaign $CAMPAIGN_ID"

step "scheduler -> amplify-jobs POST /runs -> chat-stub got the card"
card_posted() { internal_get chat-stub http://localhost:9095/stub/messages | grep -q "$TITLE"; }
wait_for 60 "Google Chat card for '$TITLE'" card_posted
run_ok() { internal_get amplify-api http://scheduler:8080/jobs/amplify-run/history | grep -q '"status":"completed"'; }
wait_for 30 "scheduler job history shows a successful amplify-run" run_ok

step "connect LinkedIn via mock OAuth"
if call "$EMP_JWT" GET /me | jq -e '.linkedin.status | IN("NOT_CONNECTED", "REMOVED") | not' >/dev/null; then
  call "$EMP_JWT" DELETE /connections/linkedin >/dev/null
  echo "rerun: removed the previous connection"
fi
start=$(call "$EMP_JWT" POST /connections/linkedin/start '{}')
AUTH_URL=$(jq -r '.authorizationUrl' <<<"$start")
[[ "$AUTH_URL" == http://localhost:19091/* ]] || fail "authorization URL is not browser-reachable: $AUTH_URL"
redirect=$(curl -sS -o /dev/null -w '%{redirect_url}' "$AUTH_URL")
CODE=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$redirect")
STATE=$(sed -n 's/.*[?&]state=\([^&]*\).*/\1/p' <<<"$redirect")
[[ -n "$CODE" && -n "$STATE" ]] || fail "mock OAuth did not redirect with code+state: $redirect"
call "$EMP_JWT" POST /connections/linkedin/complete "{\"code\":\"$CODE\",\"state\":\"$STATE\"}" >/dev/null
call "$EMP_JWT" GET /me | jq -e '.linkedin.status == "ACTIVE"' >/dev/null || fail "connection not ACTIVE"
echo "ok: LinkedIn ACTIVE"

step "share (REPOST)"
call "$EMP_JWT" POST "/campaigns/$CAMPAIGN_ID/shares" '{"kind":"REPOST"}' >/dev/null
published() { call "$EMP_JWT" GET /me/shares | jq -e --arg c "$CAMPAIGN_ID" \
  '[.. | objects | select(.campaignId? == $c and .status? == "PUBLISHED")] | length > 0'; }
wait_for 60 "share PUBLISHED on mock LinkedIn" published

step "points + leaderboard"
has_points() { call "$EMP_JWT" GET /me/points | jq -e '[.. | objects | .total? // .totalPoints? // .points? | numbers] | max > 0'; }
wait_for 60 "points awarded" has_points
call "$EMP_JWT" GET /me/points | jq -c .
on_board() { call "$EMP_JWT" GET /leaderboard | grep -q "$EMP_EMAIL"; }
wait_for 30 "employee on the leaderboard" on_board
call "$EMP_JWT" GET /leaderboard | jq -c '.personal // .'

step "restore run.schedule -> @every 5m"
version=$(call "$ADMIN_JWT" GET /admin/settings | jq -r '.settings[] | select(.key == "run.schedule") | .version')
call "$ADMIN_JWT" PUT /admin/settings \
  "{\"changes\":[{\"key\":\"run.schedule\",\"value\":\"@every 5m\",\"version\":$version}]}" >/dev/null

printf '\nE2E PASSED\n'
