// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// Authentication for the worker's own endpoints (security review, "back-office components").
//
// amplify-jobs is on Project visibility only, but anything else in the project (or a compromised pod) could
// reach it, and `POST /runs`, `/maintenance/partitions` and `/maintenance/rebuild-recognition` are the strongest
// operations Amplify has. Every call except the two probes must carry the shared internal key. Callers are the
// scheduler (the key is set as a header on each job amplify-api pushes) and amplify-api ("Save & Share Now").

import amplify_common.crypto;

import ballerina/http;
import ballerina/log;

# Header the scheduler and amplify-api send; the same name amplify-api puts on the jobs it registers.
const string INTERNAL_KEY_HEADER = "X-Amplify-Internal-Key";

# Shared secret for calls into amplify-jobs (a Choreo secret; locally `AMPLIFY_INTERNAL_API_KEY`). Required: the
# worker does not start without it, so a missing secret can never leave the endpoints open.
configurable string internalApiKey = ?;

# Refuses every request that does not carry the internal key, except the liveness and readiness probes.
public isolated service class InternalKeyInterceptor {
    *http:RequestInterceptor;

    isolated resource function 'default [string... path](http:RequestContext ctx, http:Request req)
            returns http:NextService|http:Unauthorized|error? {
        if req.method == http:GET && path.length() == 1 && (path[0] == "health" || path[0] == "ready") {
            return ctx.next();
        }
        string|http:HeaderNotFoundError presented = req.getHeader(INTERNAL_KEY_HEADER);
        if presented is string && keyMatches(presented, internalApiKey) {
            return ctx.next();
        }
        // The route and whether a key was sent, never the key itself.
        log:printWarn("Internal call refused", route = req.method + " /" + string:'join("/", ...path),
                keySent = presented is string);
        return <http:Unauthorized>{body: {message: "Unauthorized"}};
    }
}

# Whether a presented key is the configured one. Both sides are trimmed: amplify-api and the scheduler send the
# trimmed value, and a secret mounted from a file often ends in a newline, which would otherwise be accepted at
# start-up and then refuse every call.
#
# + presented - Key from the request header
# + configured - `internalApiKey`
# + return - True when equal, compared in constant time
isolated function keyMatches(string presented, string configured) returns boolean =>
    crypto:constantTimeEquals(presented.trim(), configured.trim());

# Stops start-up when the key is blank or too short to be a secret.
#
# + key - The configured key
# + return - An error naming the problem, or `()`
isolated function checkInternalKey(string key) returns error? {
    if key.trim().length() < MIN_INTERNAL_KEY_LENGTH {
        return error(string `internalApiKey must be set to a secret of at least ${MIN_INTERNAL_KEY_LENGTH} characters`);
    }
}

# Shortest secret accepted (a 24-byte random value as hex is 48).
const int MIN_INTERNAL_KEY_LENGTH = 32;
