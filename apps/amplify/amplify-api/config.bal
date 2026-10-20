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
import amplify_api.auth;

import ballerina/io;
import ballerina/log;

// ---- Identity (ADR-022). Setup values: docs/runbooks/identity-setup.md ----------------------------

# Deployment environment: `local`, `dev`, `staging` or `prod`. Defaults to the strictest.
configurable string environment = "prod";
# Header the API proxy puts the backend JWT in.
configurable string jwtHeader = "x-jwt-assertion";
# Gateway JWKS URL (Choreo backend JWT signing keys).
configurable string gatewayJwksUrl = ?;
# Gateway backend JWT `iss`.
configurable string gatewayIssuer = ?;
# Accepted backend JWT `aud` values, comma separated (a string so `BAL_CONFIG_VAR_*` can set it).
configurable string gatewayAudiences = ?;
# Claim carrying Asgardeo groups.
configurable string rolesClaim = "groups";
# Email claim.
configurable string emailClaim = "email";
# Display name claim.
configurable string nameClaim = "name";
# Allowed clock skew, seconds.
configurable int clockSkewSeconds = 60;
# JWKS refresh age, seconds.
configurable decimal jwksRefreshSeconds = 3600;
# Minimum seconds between refreshes for unknown `kid` / stale keys.
configurable decimal jwksMinRefreshIntervalSeconds = 30;
# JWKS HTTP timeout, seconds.
configurable decimal jwksTimeoutSeconds = 5;
# JWKS breaker reset, seconds.
configurable decimal jwksBreakerResetSeconds = 30;

// ---- Dev-only local signing (ADR-023). Refused unless environment = "local" ---------------------

# Accept tokens signed by a local key (no API proxy). Off by default.
configurable boolean devLocalJwtEnabled = false;
# Local JWKS file with the dev public key(s).
configurable string devJwksFile = "";
# `iss` of locally signed tokens; must differ from `gatewayIssuer`.
configurable string devIssuer = "amplify-local-dev";

final auth:TokenVerifier verifier = check newVerifier();

isolated function newVerifier() returns auth:TokenVerifier|error {
    check checkDevSwitch(environment, devLocalJwtEnabled, devIssuer, gatewayIssuer);
    auth:DevTrust? dev = ();
    if devLocalJwtEnabled {
        dev = {issuer: devIssuer, keys: check auth:parseJwks(check io:fileReadJson(devJwksFile))};
        log:printWarn("DEV-ONLY: accepting locally signed JWTs (ADR-023). Never enable outside local Docker.",
                issuer = devIssuer);
    }
    auth:JwksCache jwks = check new ({
        url: gatewayJwksUrl,
        refreshSeconds: jwksRefreshSeconds,
        minRefreshIntervalSeconds: jwksMinRefreshIntervalSeconds,
        timeoutSeconds: jwksTimeoutSeconds,
        breakerResetSeconds: jwksBreakerResetSeconds
    });
    return new (jwks, {
        issuer: gatewayIssuer,
        audiences: from string a in re `,`.split(gatewayAudiences) where a.trim().length() > 0 select a.trim(),
        clockSkewSeconds,
        rolesClaim,
        emailClaim,
        nameClaim
    }, dev);
}

# Refuses to start with the dev switch outside local Docker (ADR-023).
#
# + env - `environment`
# + enabled - `devLocalJwtEnabled`
# + localIssuer - `devIssuer`
# + realIssuer - `gatewayIssuer`
# + return - An error that stops startup, or `()`
isolated function checkDevSwitch(string env, boolean enabled, string localIssuer, string realIssuer) returns error? {
    if !enabled {
        return;
    }
    if env != "local" {
        return error(string `devLocalJwtEnabled is refused when environment is '${env}' (only 'local')`);
    }
    if localIssuer.trim().length() == 0 || localIssuer == realIssuer {
        return error("devIssuer must be set and differ from gatewayIssuer");
    }
}
