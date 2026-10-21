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

// Novera, the Google Chat assistant (feat/amplify_on_novera). A campaign announcement goes to
// `POST /internal/notifications`, and Novera sends it as a card to everyone who has a chat open with it.
// Mirrors the Today I Learned backend's novera client (cs-tools apps/today-i-learned/backend/internal/novera).
// Novera answers 202 before it has sent anything, so there is no message name to keep. A 503 means Novera
// couldn't get a Google token and sent nothing: retryable. No HTTP-level retry: the outbox retries (ADR-025).

import amplify_common.resilience;
import amplify_domain.announcements;

import ballerina/http;

# Why Novera did not accept an announcement.
type NoveraErrorDetail record {|
    # `UNAVAILABLE`, `RATE_LIMITED` or `REJECTED`
    string code;
    # HTTP status, `()` when there was no response
    int? httpStatus;
    # True when the outbox should try again
    boolean retryable;
|};

type NoveraError distinct error<NoveraErrorDetail>;

# Port to Novera's notifications endpoint.
type NoveraPort isolated object {
    isolated function notify(announcements:NoveraNotification notification, string? correlationId)
        returns NoveraError?;
    isolated function breaker() returns string;
};

# `NoveraPort` over the Choreo gateway, with a client-credentials token from an application subscribed to
# Novera's API.
isolated class NoveraClient {
    *NoveraPort;

    private final http:Client httpClient;
    private final string path;

    # + notifyUrl - Novera's `POST /internal/notifications` URL (https)
    # + tokenUrl - Token endpoint
    # + clientId - Client id of the subscribed application
    # + clientSecret - Client secret
    # + scopes - Token scopes
    # + timeoutSeconds - Per-call timeout (token and notification)
    # + settings - Breaker and pool settings
    # + return - An error when the URL is not https or the client can't be built
    isolated function init(string notifyUrl, string tokenUrl, string clientId, string clientSecret, string[] scopes,
            decimal timeoutSeconds, resilience:HttpResilience settings = {}) returns error? {
        string url = notifyUrl.trim();
        if !url.toLowerAscii().startsWith("https://") {
            return error("Novera notify URL must be HTTPS");
        }
        int pathStart = url.indexOf("/", 8) ?: url.length();
        http:ClientConfiguration config = resilience:clientConfig(settings, timeoutSeconds);
        http:OAuth2ClientCredentialsGrantConfig grant = {tokenUrl, clientId, clientSecret, scopes};
        config.auth = grant;
        self.httpClient = check new (url.substring(0, pathStart), config);
        string path = url.substring(pathStart);
        self.path = path.length() == 0 ? "/" : path;
    }

    isolated function notify(announcements:NoveraNotification notification, string? correlationId)
            returns NoveraError? {
        http:Response|http:ClientError response = self.httpClient->post(self.path, notification.toJson(),
                resilience:correlationHeaders(correlationId));
        if response is http:ClientError {
            return noveraError("UNAVAILABLE", "Novera call failed: no response", (), true);
        }
        int status = response.statusCode;
        if status == http:STATUS_ACCEPTED || status == http:STATUS_OK {
            return;
        }
        if status == http:STATUS_TOO_MANY_REQUESTS {
            return noveraError("RATE_LIMITED", "Novera rate limited", status, true);
        }
        if status >= 500 {
            return noveraError("UNAVAILABLE", string `Novera failed with HTTP ${status}`, status, true);
        }
        return noveraError("REJECTED", string `Novera refused the announcement with HTTP ${status}`, status, false);
    }

    isolated function breaker() returns string => resilience:breakerState(self.httpClient);
}

isolated function noveraError(string code, string message, int? httpStatus, boolean retryable) returns NoveraError =>
    error NoveraError(message, code = code, httpStatus = httpStatus, retryable = retryable);
