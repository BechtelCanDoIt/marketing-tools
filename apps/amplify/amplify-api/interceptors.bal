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

import ballerina/http;
import ballerina/log;
import ballerina/uuid;

# Runs before every resource: verifies the gateway's backend JWT (signature against the JWKS, then
# `iss`/`aud`/`exp`), then enforces the activity matrix (role × method × route). Probes skip it.
# Denials return problem details and are written to `audit.audit_log`; logs carry the code and route
# only, never the token or the caller's email.
isolated service class AuthInterceptor {
    *http:RequestInterceptor;

    isolated resource function 'default [string... path](http:RequestContext ctx, http:Request req)
            returns http:NextService|http:Unauthorized|http:Forbidden|http:ServiceUnavailable|error? {
        string correlationId = assignCorrelationId(ctx, req);
        if req.method == http:GET && auth:isPublic(path) {
            return ctx.next();
        }
        string|http:HeaderNotFoundError header = req.getHeader(jwtHeader);
        auth:Principal|auth:AuthError principal = verifier.verify(header is string ? header.toString() : ());
        if principal is auth:AuthError {
            string code = principal.detail().code;
            if code == auth:KEYS_UNAVAILABLE {
                log:printError("Token keys unavailable", errorCode = code, correlationId = correlationId);
                return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
            }
            deny(ANONYMOUS, [], routeOf(req.method, path, ()), code, correlationId);
            return unauthorized(code, principal.message(), correlationId);
        }

        auth:Rule? rule = auth:findRule(req.method, path);
        if rule is () {
            deny(principal.employeeId, principal.roles, routeOf(req.method, path, ()), ROUTE_NOT_PERMITTED,
                    correlationId);
            return forbidden(ROUTE_NOT_PERMITTED, correlationId);
        }
        if !auth:isAllowed(rule, principal.roles) {
            deny(principal.employeeId, principal.roles, routeOf(req.method, path, rule), ROLE_NOT_PERMITTED,
                    correlationId);
            return forbidden(ROLE_NOT_PERMITTED, correlationId);
        }
        ctx.set(PRINCIPAL_KEY, principal.cloneReadOnly());
        return ctx.next();
    }
}

# Logs a denial and writes its audit row. A failed audit write is logged; the call is still denied.
#
# + actorId - Employee id, or `anonymous`
# + roles - Caller's roles
# + route - `METHOD /template`
# + code - Stable denial code
# + correlationId - Correlation id
isolated function deny(string actorId, string[] roles, string route, string code, string? correlationId) {
    log:printWarn("Access denied", errorCode = code, route = route, correlationId = correlationId);
    error? written = recordDenial({
        actorId,
        actorRoles: roles,
        action: ACCESS_DENIED,
        entityType: ROUTE_ENTITY,
        entityId: route,
        outcome: "DENIED",
        reason: code,
        correlationId
    });
    if written is error {
        log:printError("Could not write the denial audit row", written, errorCode = code, route = route);
    }
}

# Route label for logs and audit: the matrix template when known, else the raw path (truncated).
#
# + method - HTTP method
# + path - Path segments
# + rule - Matched row, if any
# + return - For example `GET /po/dashboard`
isolated function routeOf(string method, string[] path, auth:Rule? rule) returns string {
    string raw = rule is auth:Rule ? rule.path : "/" + string:'join("/", ...path);
    string route = method.toUpperAscii() + " " + raw;
    return route.length() > 200 ? route.substring(0, 200) : route;
}

# The verified caller set by the interceptor.
#
# + ctx - Request context
# + return - The principal, or an error if the interceptor didn't run
isolated function principalOf(http:RequestContext ctx) returns auth:Principal|error =>
    ctx.getWithType(PRINCIPAL_KEY);

# Correlation id from the caller, if it's safe to echo and store.
#
# + req - Request
# + return - The id, or `()`
isolated function correlationIdOf(http:Request req) returns string? {
    string|http:HeaderNotFoundError id = req.getHeader(CORRELATION_HEADER);
    return id is string && re `[A-Za-z0-9._\-]{1,64}`.isFullMatch(id) ? id : ();
}

# Takes the caller's correlation id (or makes one) and keeps it on the request context, so logs, audit,
# outbox rows and the jobs trigger all carry it and the response echoes it.
#
# + ctx - Request context
# + req - Request
# + return - The id
isolated function assignCorrelationId(http:RequestContext ctx, http:Request req) returns string {
    string id = correlationIdOf(req) ?: uuid:createType4AsString();
    ctx.set(CORRELATION_KEY, id);
    return id;
}

# The request's correlation id (set by `AuthInterceptor`).
#
# + ctx - Request context
# + return - The id, or `()` outside a request
isolated function cid(http:RequestContext ctx) returns string? {
    string|error id = ctx.getWithType(CORRELATION_KEY);
    return id is string ? id : ();
}

# Adds the API security headers (plan M5) and echoes `X-Correlation-ID` on every response, errors and
# probes included.
isolated service class SecurityHeadersInterceptor {
    *http:ResponseInterceptor;

    isolated remote function interceptResponse(http:RequestContext ctx, http:Response res) returns http:NextService|error? {
        res.setHeader("X-Content-Type-Options", "nosniff");
        res.setHeader("Content-Security-Policy", "upgrade-insecure-requests");
        res.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
        // Responses carry personal data (emails, points): nothing caches them unless the resource says so
        // (`/leaderboard` and `/po/dashboard` set `private, max-age`).
        if !res.hasHeader("Cache-Control") {
            res.setHeader("Cache-Control", "no-store");
        }
        string? id = cid(ctx);
        if id is string {
            res.setHeader(CORRELATION_HEADER, id);
        }
        return ctx.next();
    }
}

# Turns errors the resources didn't map (an `error` return, a failed payload or query binding, an
# unmatched route) into problem details. The error text goes to the log only.
isolated service class ResponseErrorMapper {
    *http:ResponseErrorInterceptor;

    isolated remote function interceptResponseError(http:RequestContext ctx, error err) returns http:Response {
        return errorResponse(ctx, err);
    }
}

# Same mapping for errors raised on the request path (data binding happens before the resource).
isolated service class RequestErrorMapper {
    *http:RequestErrorInterceptor;

    isolated resource function 'default [string... path](http:RequestContext ctx, error err) returns http:Response {
        return errorResponse(ctx, err);
    }
}

isolated function errorResponse(http:RequestContext ctx, error err) returns http:Response {
    string? id = cid(ctx);
    int status = 500;
    string code = INTERNAL_ERROR;
    string detail = "Something went wrong on our side";
    string title = "Internal Server Error";
    if err is http:PayloadBindingError || err is http:QueryParameterBindingError || err is http:HeaderBindingError
            || err is http:PathParameterBindingError || err is http:PayloadValidationError
            || err is http:QueryParameterValidationError || err is http:HeaderValidationError {
        status = 400;
        code = VALIDATION_FAILED;
        title = "Bad Request";
        detail = "The request is malformed or has invalid fields";
        log:printDebug("Request rejected by binding", 'error = err, correlationId = id);
    } else if err is http:ResourceDispatchingError {
        var sc = err.detail()["statusCode"];
        status = sc is int ? sc : 404;
        code = status == 404 ? NOT_FOUND : status == 405 ? METHOD_NOT_ALLOWED : VALIDATION_FAILED;
        title = status == 404 ? "Not Found" : status == 405 ? "Method Not Allowed" : "Bad Request";
        detail = status == 404 ? "No such resource" : "The request can't be routed";
    } else {
        log:printError("Unhandled error", err, correlationId = id);
    }
    http:Response res = new;
    res.statusCode = status;
    res.setJsonPayload(problem(status, title, code, detail, id).toJson(), PROBLEM_JSON);
    return res;
}
