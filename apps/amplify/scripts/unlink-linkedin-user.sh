#!/usr/bin/env bash
# Local demo helper: unlinks a user's LinkedIn connection in the local stack so the link flow can be shown again.
#
#   scripts/unlink-linkedin-user.sh <Developer Email>
#
# The employee id is the JWT `sub`, so it is looked up by email in the local database (identity.employee).
# The user must have signed in to Amplify at least once. Works from any directory.
# Expect "204 Removed". 404 = nothing linked, 409 = already removed.
set -euo pipefail
cd "$(dirname "$0")/.."

email="${1:-}"
if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
  echo "usage: $0 <email>" >&2
  exit 2
fi

# The email is passed to psql as a variable (:'email'), never pasted into the SQL text. The banner scripts/compose.sh
# prints goes to stderr, so it is dropped here.
ids="$(printf "select employee_id from identity.employee where lower(email) = lower(:'email');\n" |
  scripts/compose.sh exec -T -e EMAIL="$email" postgres sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d amplify -At -v email="$EMAIL"' 2>/dev/null || true)"

case "$(printf '%s' "$ids" | grep -c .)" in
  1) employee_id="$ids" ;;
  0) echo "No employee with email $email in the local database (have they signed in to Amplify yet? is the stack up?)" >&2; exit 1 ;;
  *) echo "More than one employee matches $email; refusing to guess." >&2; exit 1 ;;
esac

TOKEN="$(local/dev-jwt/mint-dev-jwt.sh token "$employee_id" "$email")"
echo "Unlinking LinkedIn for $email ($employee_id)"
response="$(curl -sS -w '\n%{http_code}' -X DELETE http://localhost:9090/connections/linkedin \
  -H "x-jwt-assertion: ${TOKEN}")"
status="${response##*$'\n'}"
case "$status" in
  204) echo "204 Removed" ;;
  *) echo "$status"; echo "${response%$'\n'*}"; exit 1 ;;
esac
