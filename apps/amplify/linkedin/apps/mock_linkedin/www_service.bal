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
import mock_linkedin.store;

import ballerina/http;
import ballerina/log;

# Listener for the `www.linkedin.com` host.
listener http:Listener wwwListener = new (wwwPort, host = listenerHost);

# Mock of LinkedIn's 3-legged OAuth 2.0 authorization code flow. There is no login page:
# every authorization signs in as the configured `member` and consents straight away.
@display {
    label: "Mock LinkedIn OAuth 2.0",
    id: "linkedin/mock-oauth"
}
service http:InterceptableService /oauth/v2 on wwwListener {

    # Correlation id, logging and LinkedIn-shaped errors. No bearer token on these endpoints.
    #
    # + return - Interceptor pipeline
    public isolated function createInterceptors() returns http:Interceptor[] =>
        [new ResponseInterceptor(), new ErrorInterceptor(), new CorrelationInterceptor()];

    # Authorization endpoint. Redirects back to the app with a code, or with an error.
    #
    # + ctx - Request context
    # + response_type - Must be `code`
    # + client_id - App client id
    # + redirect_uri - Registered redirect URI
    # + scope - Space or comma separated scopes
    # + state - Opaque value echoed back to the app
    # + mock_consent - Mock only. Set to `deny` to simulate the member cancelling
    # + return - 302 to the redirect URI, or 400 if the client or redirect URI is wrong
    isolated resource function get authorization(http:RequestContext ctx, string? response_type, string? client_id, string? redirect_uri,
            string? scope, string? state, string? mock_consent)
            returns http:Found|OAuthErrorBadRequest|ErrorInternalServerError {
        if client_id != clientId {
            return oauthBadRequest(OAUTH_INVALID_CLIENT, "The passed in client_id is invalid");
        }
        if redirect_uri is () || redirectUris.indexOf(redirect_uri) is () {
            return oauthBadRequest(OAUTH_INVALID_REDIRECT_URI,
                    "The redirect_uri does not match the registered value");
        }

        map<string> params = {};
        if response_type != RESPONSE_TYPE_CODE {
            params = {'error: OAUTH_UNSUPPORTED_RESPONSE_TYPE, error_description: "response_type must be code"};
        } else {
            string[]|OAuthError scopes = parseScopes(scope);
            if scopes is OAuthError {
                params = {'error: scopes.'error, error_description: scopes.error_description};
            } else if mock_consent == MOCK_CONSENT_DENY {
                params = {'error: OAUTH_USER_CANCELLED, error_description: "The user cancelled the authorization"};
            } else {
                string code = randomOpaqueValue();
                store:putAuthorizationCode({
                    code,
                    clientId,
                    redirectUri: redirect_uri,
                    scopes: scopes.cloneReadOnly(),
                    memberSub: member.sub,
                    expiresAt: nowSeconds() + <decimal>authorizationCodeTtlSeconds
                });
                log:printInfo("Authorization code issued", correlationId = correlationId(ctx), scopes = scopes);
                params = {code};
            }
        }
        if state is string {
            params["state"] = state;
        }

        string|error location = withQuery(redirect_uri, params);
        if location is error {
            log:printError("Failed to build the authorization redirect", location, correlationId = correlationId(ctx));
            return <ErrorInternalServerError>{body: {status: http:STATUS_INTERNAL_SERVER_ERROR, message: MSG_INTERNAL_ERROR}};
        }
        return <http:Found>{headers: {[HEADER_LOCATION]: location}};
    }

    # Token endpoint. Exchanges an authorization code for an access token.
    #
    # + ctx - Request context
    # + req - Form-encoded token request
    # + return - Access token, or an OAuth error
    isolated resource function post accessToken(http:RequestContext ctx, http:Request req)
            returns AccessTokenResponseOk|OAuthErrorBadRequest|OAuthErrorUnauthorized {
        map<string>|http:ClientError form = req.getFormParams();
        if form is http:ClientError {
            log:printDebug("Token request rejected: body is not form encoded", correlationId = correlationId(ctx),
                    reason = form.message());
            return oauthBadRequest(OAUTH_INVALID_REQUEST, "Request body must be application/x-www-form-urlencoded");
        }
        if form["grant_type"] != GRANT_TYPE_AUTHORIZATION_CODE {
            return oauthBadRequest(OAUTH_UNSUPPORTED_GRANT_TYPE, "grant_type must be authorization_code");
        }
        if form["client_id"] != clientId || form["client_secret"] != clientSecret {
            return <OAuthErrorUnauthorized>{body: {'error: OAUTH_INVALID_CLIENT, error_description: "Client authentication failed"}};
        }
        string? codeValue = form["code"];
        store:AuthorizationCode? code = codeValue is string ? store:takeAuthorizationCode(codeValue) : ();
        if code is () || code.expiresAt <= nowSeconds() || code.clientId != clientId
                || code.redirectUri != form["redirect_uri"] {
            return oauthBadRequest(OAUTH_INVALID_REQUEST, MSG_TOKEN_EXCHANGE_FAILED);
        }

        string accessToken = randomOpaqueValue() + randomOpaqueValue();
        int revoked = store:issueAccessToken({
            value: accessToken,
            clientId,
            memberSub: code.memberSub,
            scopes: code.scopes,
            expiresAt: nowSeconds() + <decimal>tokenTtlSeconds
        });
        log:printInfo("Access token issued", correlationId = correlationId(ctx), scopes = code.scopes, revokedTokens = revoked);
        return <AccessTokenResponseOk>{
            body: {
                access_token: accessToken,
                expires_in: tokenTtlSeconds,
                scope: string:'join(",", ...code.scopes),
                token_type: TOKEN_TYPE_BEARER
            }
        };
    }
}

# Parses the `scope` parameter and checks every scope is one the mock supports.
#
# + scope - Space or comma separated scopes
# + return - Scopes without duplicates, or an OAuth error
isolated function parseScopes(string? scope) returns string[]|OAuthError {
    string[] scopes = [];
    foreach string item in re `[\s,+]+`.split((scope ?: "").trim()) {
        if item == "" || scopes.indexOf(item) !is () {
            continue;
        }
        if SUPPORTED_SCOPES.indexOf(item) is () {
            return {'error: OAUTH_UNAUTHORIZED_SCOPE, error_description: string `Scope "${item}" is not authorized for your application`};
        }
        scopes.push(item);
    }
    if scopes.length() == 0 {
        return {'error: OAUTH_INVALID_REQUEST, error_description: "scope is required"};
    }
    return scopes;
}

# Mock of the image upload host. Upload URLs come from `/rest/images` or `/v2/assets`.
@display {
    label: "Mock LinkedIn Media Upload",
    id: "linkedin/mock-media-upload"
}
service http:InterceptableService /dms\-uploads on wwwListener {

    # Correlation id, logging and LinkedIn-shaped errors. The resource checks the bearer token.
    #
    # + return - Interceptor pipeline
    public isolated function createInterceptors() returns http:Interceptor[] =>
        [new ResponseInterceptor(), new ErrorInterceptor(), new CorrelationInterceptor()];

    # Upload the image bytes.
    #
    # + uploadPath - Path segments from the upload URL. The first is the upload id
    # + ctx - Request context
    # + req - Request with the binary body and bearer token
    # + return - 201, or an error
    isolated resource function put [string... uploadPath](http:RequestContext ctx, http:Request req)
            returns http:Created|ErrorBadRequest|ErrorUnauthorized|ErrorForbidden|ErrorNotFound {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authenticateWithScope(req, SCOPE_W_MEMBER_SOCIAL, "PUT /dms-uploads");
        if token !is store:AccessToken {
            return token;
        }
        store:Upload? upload = uploadPath.length() > 0 ? store:getUpload(uploadPath[0]) : ();
        if upload is () {
            return notFound("Upload URL not found");
        }
        ErrorForbidden? notMember = checkIsMember(upload.ownerUrn, token);
        if notMember is ErrorForbidden {
            return notMember;
        }
        if upload.expiresAt <= nowSeconds() {
            return badRequest("Upload URL has expired");
        }
        byte[]|http:ClientError body = req.getBinaryPayload();
        if body is http:ClientError {
            log:printDebug("Upload rejected: unreadable body", correlationId = correlationId(ctx),
                    reason = body.message());
            return badRequest(MSG_INVALID_UPLOAD_BODY);
        }
        if body.length() == 0 {
            return badRequest(MSG_INVALID_UPLOAD_BODY);
        }
        store:putUpload({
            uploadId: upload.uploadId,
            mediaUrn: upload.mediaUrn,
            ownerUrn: upload.ownerUrn,
            expiresAt: upload.expiresAt,
            uploaded: true
        });
        log:printInfo("Media uploaded", correlationId = correlationId(ctx), media = upload.mediaUrn, bytes = body.length());
        return http:CREATED;
    }
}
