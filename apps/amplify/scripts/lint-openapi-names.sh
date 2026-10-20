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
# Ubiquitous-language lint for the OpenAPI contracts (plan M2/M5): L2-era words `post` and `submission`
# must not appear in paths, operationIds, schema names or property names. Use Campaign, Share,
# External share. Enum values (e.g. the OWN_POST action), descriptions and the HTTP `post:` method key
# are not names and are skipped.
#
# External-API names are allowed: a name that starts with an external provider (`linkedinPosts`, the
# count of LinkedIn `/rest/posts` calls in the jobs run report) speaks LinkedIn's language about
# LinkedIn's resource, not Amplify's. The rule is about Amplify's own nouns. Add a provider to
# `external` only when the name really counts or carries that provider's resource.
#
# Usage: scripts/lint-openapi-names.sh [openapi.yaml ...]   (default: every amplify-*/openapi.yaml)
set -euo pipefail
cd "$(dirname "$0")/.."
files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  files=(amplify-*/openapi.yaml)
fi
# A banned word as a whole name segment: at the start (any case) or a camel/snake segment (`Post`,
# `_post`). `reposters` and `OWN_POST`-style enum values don't match.
seg='(post|submission)'
word="(^|[^A-Za-z])(${seg}|Post|Submission|POST|SUBMISSION)|[a-z0-9](Post|Submission)"
external='^(linkedin)[A-Z]'

status=0
for f in "${files[@]}"; do
  # 1. Paths: top-level keys under `paths:` (two-space indent, start with /).
  hits=$(grep -nE '^  /' "$f" | grep -iE "/[^ ]*${seg}" || true)
  # 2. operationId values.
  hits+=$'\n'$(grep -nE 'operationId:' "$f" | sed -E 's/.*operationId: *//' | grep -E "$word" || true)
  # 3. Mapping keys (schema and property names), minus the HTTP method keys at four-space indent.
  hits+=$'\n'$(grep -nE '^ *[A-Za-z_][A-Za-z0-9_]*:' "$f" \
    | grep -vE '^[0-9]+:    (get|post|put|patch|delete|options|head):' \
    | sed -E 's/^([0-9]+:) *([A-Za-z0-9_]+):.*/\1 \2/' \
    | awk '{print $2}' | grep -E "$word" | grep -vE "$external" || true)
  # 4. Keys in flow mappings, e.g. `{name: postId, ...}` parameter names.
  hits+=$'\n'$(grep -oE 'name: *[A-Za-z0-9_-]+' "$f" | sed -E 's/name: *//' | grep -E "$word" | grep -vE "$external" || true)
  hits=$(printf '%s\n' "$hits" | sed '/^$/d')
  if [ -n "$hits" ]; then
    echo "$f: banned names (use the ubiquitous language: Campaign, Share, External share):"
    echo "$hits"
    status=1
  fi
done
[ $status -eq 0 ] && echo "lint-openapi-names: OK (${files[*]})"
exit $status
