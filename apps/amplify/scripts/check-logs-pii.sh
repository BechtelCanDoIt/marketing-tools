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

# Log hygiene check (plan M9): no PII, tokens or commentary in logs. Scans every `log:print*` call in the
# Ballerina sources (tests and build output excluded), joining multi-line calls, and fails when a call
# passes a sensitive value as a key-value field (`email = ...`) or interpolates one into the message
# (`${p.email}`). A reviewed exception carries `// log-pii: ok <why>` on the call's first line.
#
# Usage: scripts/check-logs-pii.sh [root]   (default: the folder above this script)
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# Field names and identifiers that hold PII, credentials or member content.
sensitive='email|e_mail|displayName|display_name|fullName|name|givenName|familyName|phone|sub|memberUrn|member_urn|token|accessToken|access_token|refreshToken|bearer|idToken|jwt|assertion|authorization|password|passwd|secret|clientSecret|client_secret|apiKey|webhookUrl|webhook_url|commentary|comment|body|payload|code|state|nonce|cookie'

files=$(find "$root" -name '*.bal' -not -path '*/target/*' -not -path '*/tests/*' -not -path '*/node_modules/*' | sort)
[ -n "$files" ] || { echo "check-logs-pii: no .bal files under $root" >&2; exit 2; }

# shellcheck disable=SC2086
perl -e '
    my $sensitive = shift @ARGV;
    my $bad = 0; my $calls = 0;
    for my $file (@ARGV) {
        open(my $fh, "<", $file) or die "$file: $!";
        my @lines = <$fh>; close $fh;
        for (my $i = 0; $i < @lines; $i++) {
            next unless $lines[$i] =~ /\blog:print(Info|Warn|Error|Debug)\s*\(/;
            my $start = $i; my $call = $lines[$i];
            my $depth = () = $call =~ /\(/g; $depth -= () = $call =~ /\)/g;
            while ($depth > 0 && $i + 1 < @lines) {
                $i++; $call .= $lines[$i];
                $depth += () = $lines[$i] =~ /\(/g; $depth -= () = $lines[$i] =~ /\)/g;
            }
            $calls++;
            next if $lines[$start] =~ m{//\s*log-pii:\s*ok};
            my @hits;
            # Key-value fields: `email = x`, `\x27token = x` (not `==`).
            while ($call =~ /[,(]\s*\x27?($sensitive)\s*=(?!=)/gi) { push @hits, "field \x27$1\x27"; }
            # Interpolations: `${p.email}`, `${token}`, `${body.commentary}`.
            while ($call =~ /\$\{([^}]*)\}/g) {
                my $expr = $1;
                for my $part (split /[^A-Za-z0-9_]+/, $expr) {
                    push @hits, "interpolates \x27$expr\x27" if $part =~ /^($sensitive)$/i;
                }
            }
            if (@hits) {
                $bad++;
                my %seen; my @u = grep { !$seen{$_}++ } @hits;
                printf "%s:%d: %s\n", $file, $start + 1, join(", ", @u);
            }
        }
    }
    printf "check-logs-pii: %d log call(s) scanned, %d flagged\n", $calls, $bad;
    exit($bad ? 1 : 0);
' "$sensitive" $files
