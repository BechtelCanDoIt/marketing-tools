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
import amplify_common.resilience;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.recognition;
import amplify_domain.store;

import ballerina/http;
import ballerina/log;
import ballerinax/postgresql;

# Port the worker listens on (Project visibility only, never published).
configurable int port = 9091;

listener http:Listener jobsListener = new (port);

function init() returns error? {
    check validateRunConfig(runConfig(), longestCallSeconds());
    log:printInfo(string `${COMPONENT} starting on port ${port}`);
    string? tls = store:tlsWarning(dbConfig());
    if tls is string {
        log:printWarn(tls);
    }
}

# Amplify worker. No internal timer: the scheduler (ADR-026) and "Save & Share Now" call it (ADR-003).
@display {
    label: "Amplify Jobs",
    id: "amplify/amplify-jobs"
}
service / on jobsListener {

    # Liveness probe.
    #
    # + return - Component health
    resource function get health() returns types:HealthStatus => {component: COMPONENT, status: types:UP};

    # Readiness probe: the database breaker isn't open and the database answers. LinkedIn, Chat and the
    # token keys are reported but don't fail readiness (a run defers those rows, ADR-025). Each probe also
    # refreshes the `amplify_breaker_state` gauges (ADR-028).
    #
    # + return - Readiness with the checks; 503 when the database is down
    resource function get ready() returns http:Ok|http:ServiceUnavailable {
        boolean database = dbBreaker.state() != "OPEN" && dbReachable();
        map<string> breakers = breakerStates();
        resilience:exportBreakerStates(COMPONENT, breakers);
        ReadyReport body = readiness(database, breakers, isRunInProgress());
        return database ? <http:Ok>{body} : <http:ServiceUnavailable>{body};
    }

    # Runs the outbox once (announcements, sharing, scoring) and returns the run log. Safe to call any time
    # and concurrently: a second caller gets 202 `SKIPPED` while a run is in progress (here or on another
    # replica). Any scheduler can call it (ADR-003).
    #
    # + correlationId - Trigger correlation id (`X-Correlation-ID`), logged with the run
    # + return - The run log, 202 when another run is in progress, 503 when the database isn't reachable,
    # or 500
    resource function post runs(@http:Header {name: "X-Correlation-ID"} string? correlationId)
            returns RunReport|http:Accepted|http:ServiceUnavailable|http:InternalServerError {
        postgresql:Client|error dbc = db();
        postgresql:Client|error lockDbc = lockDb();
        if dbc is error || lockDbc is error {
            log:printError("Run: database unavailable", resilience:loggable(dbc is error ? dbc : <error>lockDbc));
            return <http:ServiceUnavailable>{body: {message: "Database unavailable"}};
        }
        RunReport|RunSkipped|error result = runOnce(productionDeps(new PgRunStore(dbc), new PgRunLock(lockDbc)),
                correlationId);
        if result is error {
            recordDbFailure(result);
            log:printError("Run failed", resilience:loggable(result), correlationId = correlationId);
            return <http:InternalServerError>{body: {message: "Run failed"}};
        }
        if result is RunSkipped {
            log:printInfo("Run skipped: another run is in progress", correlationId = correlationId);
            return <http:Accepted>{body: result};
        }
        return result;
    }

    # Daily upkeep (B10): token and audit partitions ahead, expired token days and audit months past
    # retention dropped (each audited), DONE outbox rows purged, expired OAuth states swept.
    #
    # Also purges expired `Idempotency-Key` records (ADR-024 item 3) and re-seals token rows written under
    # an older key with the active one (key rotation; the result is in `token_rotation`, never fatal).
    #
    # + return - What was done, 503 when the database isn't reachable, or 500
    resource function post maintenance/partitions()
            returns MaintenanceReport|http:ServiceUnavailable|http:InternalServerError {
        postgresql:Client|error dbc = db();
        if dbc is error {
            log:printError("Partition maintenance: database unavailable", resilience:loggable(dbc));
            return <http:ServiceUnavailable>{body: {message: "Database unavailable"}};
        }
        store:MaintenanceResult|error result = store:runPartitionMaintenance(dbc);
        if result is error {
            recordDbFailure(result);
            log:printError("Partition maintenance failed", resilience:loggable(result));
            return <http:InternalServerError>{body: {message: "Partition maintenance failed"}};
        }
        int|error purged = store:purgeExpiredIdempotencyKeys(dbc);
        if purged is error {
            log:printError("Idempotency key purge failed", resilience:loggable(purged));
            return <http:InternalServerError>{body: {message: "Idempotency key purge failed"}};
        }
        TokenRotation rotation = rotateTokenKeys(tokenCipher, new connection:PgTokenRepository(dbc));
        MaintenanceReport report = {...result, idempotency_keys_purged: purged, token_rotation: rotation};
        log:printInfo(string `Partition maintenance done: ${report.toString()}`);
        return report;
    }

    # Rebuilds every recognition read model from the ledger (recognition is never a source of truth).
    #
    # + return - The new standing version, 503 when the database isn't reachable, or 500
    resource function post maintenance/rebuild\-recognition()
            returns RebuildResult|http:ServiceUnavailable|http:InternalServerError {
        postgresql:Client|error dbc = db();
        if dbc is error {
            log:printError("Recognition rebuild: database unavailable", resilience:loggable(dbc));
            return <http:ServiceUnavailable>{body: {message: "Database unavailable"}};
        }
        int|error version = recognition:rebuild(dbc, leaderboardTopN);
        if version is error {
            recordDbFailure(version);
            log:printError("Recognition rebuild failed", resilience:loggable(version));
            return <http:InternalServerError>{body: {message: "Recognition rebuild failed"}};
        }
        log:printInfo(string `Recognition rebuilt, standing version ${version}`);
        return {standingVersion: version};
    }
}
