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
# Fails when the deployment descriptors drift (plan M8c). Per component it compares:
#   Choreo .choreo/component.yaml  <->  OpenChoreo workload.yaml : endpoint names, ports, env names (exact)
#   Dockerfile EXPOSE                                            : same ports
#   compose.yaml service env                                     : subset of the descriptor env + LOCAL_ONLY
# No yq needed: the descriptors are written one key per line on purpose.
set -uo pipefail
cd "$(dirname "$0")/.."
LINKEDIN=linkedin/apps/mock_linkedin

# component | Choreo descriptor | workload.yaml | Dockerfile | compose service
COMPONENTS=(
  "amplify-api|.choreo/component.yaml|amplify-api/workload.yaml|amplify-api/Dockerfile|amplify-api"
  "amplify-jobs|amplify-jobs/.choreo/component.yaml|amplify-jobs/workload.yaml|amplify-jobs/Dockerfile|amplify-jobs"
  "amplify-database|amplify-database/.choreo/component.yaml|amplify-database/workload.yaml|amplify-database/Dockerfile|amplify-db-migrate"
  "amplify-scheduler|amplify-scheduler/.choreo/component.yaml|amplify-scheduler/workload.yaml|amplify-scheduler/Dockerfile|scheduler"
  "mock-linkedin|$LINKEDIN/.choreo/component.yaml|$LINKEDIN/workload.yaml|$LINKEDIN/Dockerfile|mock-linkedin"
)
# Set only in local Compose, never in Choreo/OpenChoreo (dev JWT, plain-http stub, fast schedules, no TLS to
# the local Postgres, browser-facing mock OAuth URL).
LOCAL_ONLY="BAL_CONFIG_VAR_DEVLOCALJWTENABLED BAL_CONFIG_VAR_DEVJWKSFILE BAL_CONFIG_VAR_CHATALLOWINSECUREHTTP BAL_CONFIG_VAR_NOVERAALLOWINSECUREHTTP
BAL_CONFIG_VAR_MINRUNINTERVALSECONDS BAL_CONFIG_VAR_RECONCILEDELAYSECONDS BAL_CONFIG_VAR_DBSSLMODE
BAL_CONFIG_VAR_LINKEDINAUTHORIZEBASEURL"

envs()  { grep -E '^\s*- name: (BAL_CONFIG_[A-Z_]+|DSN)\s*$' "$1" | awk '{print $3}' | sort -u; }
ports() { grep -E '^\s+port: [0-9]+' "$1" | awk '{print $2}' | sort -u; }
epnames() { awk '/^endpoints:/{e=1;next} /^[a-z]/{e=0} e && /^  - name:/{print $3}' "$1" | sort; }
exposed() { grep -E '^EXPOSE' "$1" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u; }
compose_envs() {  # env keys of one compose service, including the x-db-common anchor when merged
  awk -v svc="$1" '
    /^x-db-common:/ {a=1; next} a && /^[^ ]/ {a=0}
    a && /^  [A-Z_]+:/ {sub(":","",$1); anchor[$1]=1}
    /^  [a-z][a-z0-9-]*:$/ {s=($1==svc":")}
    s && /<<: \*db-common/ {for (k in anchor) print k}
    s && /^      (BAL_CONFIG_[A-Z_]+|DSN):/ {sub(":","",$1); print $1}
  ' compose.yaml | sort -u
}

fail=0
err() { echo "DRIFT [$1]: $2"; fail=1; }
for row in "${COMPONENTS[@]}"; do
  IFS='|' read -r name desc wl dockerfile svc <<<"$row"
  for f in "$desc" "$wl" "$dockerfile"; do [[ -f "$f" ]] || { err "$name" "missing $f"; continue 2; }; done
  grep -q '^schemaVersion: "1.2"' "$desc" || err "$name" "$desc is not schemaVersion 1.2"
  [[ "$(envs "$desc")" == "$(envs "$wl")" ]] || err "$name" "env names differ: $(diff <(envs "$desc") <(envs "$wl") | grep '^[<>]' | tr '\n' ' ')"
  [[ "$(ports "$desc")" == "$(ports "$wl")" ]] || err "$name" "ports differ ($desc vs $wl)"
  [[ "$(epnames "$desc")" == "$(epnames "$wl")" ]] || err "$name" "endpoint names differ"
  [[ "$(ports "$desc")" == "$(exposed "$dockerfile")" ]] || err "$name" "Dockerfile EXPOSE $(exposed "$dockerfile" | xargs) != descriptor ports $(ports "$desc" | xargs)"
  grep -qE '^USER 10014' "$dockerfile" || err "$name" "Dockerfile must end as USER 10014"
  [[ "$(grep -E '^USER ' "$dockerfile" | tail -1)" == "USER 10014" ]] || err "$name" "the last USER must be 10014"
  # Base images pinned by digest (tag kept for readers), mock-linkedin included (same digests, jobs H5).
  unpinned=$(grep -E '^FROM ' "$dockerfile" | grep -v '@sha256:[0-9a-f]\{64\}' | grep -vE '^FROM [a-z0-9_-]+$' || true)
  [[ -z "$unpinned" ]] || err "$name" "base image not pinned by digest: $(echo $unpinned)"
  allowed=$(printf '%s\n' $(envs "$desc") $LOCAL_ONLY | sort -u)
  extra=$(comm -23 <(compose_envs "$svc") <(echo "$allowed"))
  [[ -z "$extra" ]] || err "$name" "compose service $svc sets names unknown to $desc: $(echo $extra)"
  [[ -n "$(compose_envs "$svc")" ]] || err "$name" "compose service $svc has no config env (parse error?)"
done
# Every compose image and the local-only Dockerfiles (chat-stub, people-stub) are pinned by digest too.
for f in local/chat-stub/Dockerfile local/people-stub/Dockerfile; do
  unpinned=$(grep -E '^FROM ' "$f" | grep -v '@sha256:[0-9a-f]\{64\}' || true)
  [[ -z "$unpinned" ]] || err "$f" "base image not pinned by digest: $(echo $unpinned)"
done
unpinned=$(grep -E '^\s+image: ' compose.yaml | grep -v '@sha256:[0-9a-f]\{64\}' || true)
[[ -z "$unpinned" ]] || err compose.yaml "image not pinned by digest: $(echo $unpinned)"
# Only amplify-api (9090), the mock OAuth page (19091) and the local people-stub (19092) reach the host, on
# loopback (cell rules).
host_ports=$(awk '/^  [a-z][a-z0-9-]*:$/{svc=$1} /^    ports:/{p=1; next} /^    [a-z_]+:/{p=0} p && /^      - "/{print svc, $2}' compose.yaml)
while read -r svc port; do
  [[ -z "$svc" ]] && continue
  case "$svc $port" in
    'amplify-api: "127.0.0.1:9090:9090"'|'mock-linkedin: "127.0.0.1:19091:9091"') ;;
    'people-stub: "127.0.0.1:19092:9096"') ;;  # local stub only, so a local One WSO2 can read photos
    'apim: '*) ;;  # optional profile (`make up PROFILE=apim`), loopback only
    *) err compose.yaml "unexpected host port: $svc $port" ;;
  esac
  [[ "$port" == '"127.0.0.1:'* ]] || err compose.yaml "host port not on loopback: $svc $port"
done <<<"$host_ports"
[[ $fail -eq 0 ]] && echo "Descriptors in sync: ${#COMPONENTS[@]} components."
exit $fail
