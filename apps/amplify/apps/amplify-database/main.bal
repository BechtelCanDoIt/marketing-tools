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
import ballerina/crypto;
import ballerina/file;
import ballerina/io;
import ballerina/lang.regexp;
import ballerina/log;
import ballerina/sql;
import ballerina/time;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

# Folder holding the forward-only versioned scripts.
configurable string migrationsDir = "migrations";
# Folder holding the reference-data scripts, applied after the migrations.
configurable string seedDir = "seed";
# Only list pending scripts; apply nothing.
configurable boolean dryRun = false;

# Database host.
configurable string dbHost = "localhost";
# Database port.
configurable int dbPort = 5432;
# Database name.
configurable string dbName = "amplify";
# Bootstrap admin user (Choreo/Aiven `avnadmin`, local `postgres`). Needs CREATEROLE for V001.
configurable string dbUser = "postgres";
# Bootstrap admin password (secret).
configurable string dbPassword = "";
# TLS mode. `VERIFY_FULL` (default) checks the server certificate against `dbSslRootCert` and the host
# name, as the deployment security checklist requires (same default as amplify-api and amplify-jobs);
# `DISABLE` only for local Docker.
configurable postgresql:SSLMode dbSslMode = postgresql:VERIFY_FULL;
# PEM file with the CA that signs the managed Postgres certificate (Choreo file mount, set per environment
# through `BAL_CONFIG_VAR_DBSSLROOTCERT`). Empty = the driver default `~/.postgresql/root.crt`.
configurable string dbSslRootCert = "";

# Login password for `amplify_api` (secret). Empty leaves the role as it is (NOLOGIN on first run).
configurable string apiDbPassword = "";
# Login password for `amplify_jobs` (secret).
configurable string jobsDbPassword = "";
# Login password for `amplify_readonly` (secret, phase 2 reports).
configurable string readonlyDbPassword = "";

final regexp:RegExp MIGRATION_FILE = re `V[0-9]{3}__[a-z0-9_]+\.sql`;
final regexp:RegExp SEED_FILE = re `S[0-9]{3}__[a-z0-9_]+\.sql`;

# Key for the transaction-level advisory lock that serializes concurrent runners.
const int MIGRATE_LOCK_KEY = 4242001;

# Kind of a recorded script.
public type ScriptKind "MIGRATION"|"SEED";

# Result of one run.
public type RunSummary record {|
    # Scripts applied in this run, in order
    string[] applied;
    # Scripts already recorded and unchanged
    int skipped;
|};

# Amplify DB Migrate: applies pending migrations, then seeds, each in its own transaction, records them in
# `public.schema_version`, sets role passwords from secrets, and exits. Safe to rerun: applied scripts are
# skipped, and a changed applied script stops the run (forward-only).
#
# + return - Error when a script fails, an applied script changed, or the database is unreachable
@display {
    label: "Amplify DB Migrate",
    id: "amplify/amplify-db-migrate"
}
public function main() returns error? {
    string[] migrations = check listMigrations(migrationsDir);
    string[] seeds = check listScripts(seedDir, SEED_FILE);
    log:printInfo(string `Found ${migrations.length()} migration(s) in ${migrationsDir}, ${seeds.length()} seed(s) in ${seedDir}`);
    if dryRun {
        foreach string script in [...migrations, ...seeds] {
            log:printInfo(string `Listed: ${script}`);
        }
        return;
    }
    string? tls = tlsWarning(dbHost, dbSslMode);
    if tls is string {
        log:printWarn(tls);
    }
    postgresql:Client db = check new (host = dbHost, username = dbUser, password = dbPassword, database = dbName,
        port = dbPort, options = {ssl: secureSocketOf(dbSslMode, dbSslRootCert), connectTimeout: 10},
        connectionPool = {maxOpenConnections: 2, minIdleConnections: 0});
    RunSummary|error summary = migrate(db, migrationsDir, seedDir);
    if summary is error {
        log:printError("Migration run failed", summary);
        check db.close();
        return summary;
    }
    error? passwords = setRolePasswords(db, {
        amplify_api: apiDbPassword,
        amplify_jobs: jobsDbPassword,
        amplify_readonly: readonlyDbPassword
    });
    check db.close();
    if passwords is error {
        log:printError("Setting role passwords failed", passwords);
        return passwords;
    }
    log:printInfo(string `Migration run done: ${summary.applied.length()} applied, ${summary.skipped} already current`);
}

# The `ssl` client option: the root certificate is passed only when the mode verifies the server and a
# path is set (same rule as `amplify_domain.store:secureSocketOf`, which this runner doesn't depend on).
#
# + mode - TLS mode
# + rootCert - CA PEM path; blank = driver default
# + return - The `ssl` option
function secureSocketOf(postgresql:SSLMode mode, string rootCert) returns postgresql:SecureSocket {
    string cert = rootCert.trim();
    return verifiesServer(mode) && cert != "" ? {mode, rootcert: cert} : {mode};
}

# Whether the mode checks who the database server is.
#
# + mode - TLS mode
# + return - True for `VERIFY_CA` and `VERIFY_FULL`
function verifiesServer(postgresql:SSLMode mode) returns boolean =>
    mode == postgresql:VERIFY_CA || mode == postgresql:VERIFY_FULL;

# Start-up warning for a connection that doesn't verify a remote database server (same wording and local
# rule as `amplify_domain.store:tlsWarning`).
#
# + host - Database host
# + mode - TLS mode
# + return - The warning, or `()` when the server is verified or the host is local
function tlsWarning(string host, postgresql:SSLMode mode) returns string? {
    if host.trim() == "" || verifiesServer(mode) || isLocalHost(host) {
        return ();
    }
    return string `Database TLS mode ${mode} doesn't verify the server; set dbSslMode=VERIFY_FULL `
        + "and dbSslRootCert (deployment security checklist)";
}

# Hosts that never leave the machine or the local Compose network: loopback and single-label names
# (`postgres` in compose.yaml). A managed database always has a dotted host name.
#
# + host - Database host
# + return - True when local
function isLocalHost(string host) returns boolean {
    string h = host.trim().toLowerAscii();
    return h == "localhost" || h.startsWith("127.") || h == "::1" || h == "[::1]" || !h.includes(".");
}

# Applies every pending migration then every pending seed.
#
# + db - Client connected as the bootstrap admin
# + migrationsPath - Migrations folder
# + seedPath - Seed folder
# + return - What ran, or the first error
public function migrate(postgresql:Client db, string migrationsPath, string seedPath) returns RunSummary|error {
    check ensureVersionTable(db);
    RunSummary summary = {applied: [], skipped: 0};
    foreach string script in check listMigrations(migrationsPath) {
        check applyScript(db, migrationsPath, script, "MIGRATION", summary);
    }
    foreach string script in check listScripts(seedPath, SEED_FILE) {
        check applyScript(db, seedPath, script, "SEED", summary);
    }
    return summary;
}

# Lists versioned migration scripts, sorted by version.
#
# + dir - Folder to scan
# + return - Script file names, or an error if the folder can't be read
function listMigrations(string dir) returns string[]|error => listScripts(dir, MIGRATION_FILE);

# Lists scripts matching a pattern, sorted by name (the 3-digit number orders them). A `.sql` file that
# doesn't match the pattern, or two scripts with the same number, stop the run: a misnamed script would
# otherwise be skipped without a word, and two `V012` scripts would apply in name order by accident.
#
# + dir - Folder to scan
# + pattern - File name pattern
# + return - File names, or an error if the folder can't be read or holds a misnamed or duplicate script
function listScripts(string dir, regexp:RegExp pattern) returns string[]|error {
    file:MetaData[] entries = check file:readDir(dir);
    string[] names = [];
    foreach file:MetaData entry in entries {
        string name = check file:basename(entry.absPath);
        if entry.dir {
            continue;
        }
        if pattern.isFullMatch(name) {
            names.push(name);
        } else if name.toLowerAscii().endsWith(".sql") {
            return error(string `${dir}/${name} is not a valid script name (V###__snake_name.sql / S###__snake_name.sql)`);
        }
    }
    string[] sorted = names.sort();
    foreach int i in 1 ..< sorted.length() {
        if sorted[i].substring(0, 4) == sorted[i - 1].substring(0, 4) {
            return error(string `${dir}: ${sorted[i - 1]} and ${sorted[i]} share the version ${sorted[i].substring(0, 4)}`);
        }
    }
    return sorted;
}

# Version key of a script: its name without `.sql`, for example `V001__schemas_roles`.
#
# + script - File name
# + return - Version key
function versionOf(string script) returns string => script.substring(0, script.length() - 4);

function ensureVersionTable(postgresql:Client db) returns error? {
    _ = check db->execute(`
        CREATE TABLE IF NOT EXISTS public.schema_version (
            version      text        PRIMARY KEY,
            kind         text        NOT NULL CHECK (kind IN ('MIGRATION', 'SEED')),
            checksum     text        NOT NULL,
            applied_at   timestamptz NOT NULL DEFAULT now(),
            applied_by   text        NOT NULL DEFAULT current_user,
            execution_ms int         NOT NULL
        )`);
}

function applyScript(postgresql:Client db, string dir, string script, ScriptKind kind, RunSummary summary)
        returns error? {
    string path = check file:joinPath(dir, script);
    string content = check io:fileReadString(path);
    string checksum = crypto:hashSha256(content.toBytes()).toBase16();
    string version = versionOf(script);
    time:Utc started = time:utcNow();
    boolean applied = false;
    transaction {
        // Serialize concurrent runners; re-check after the lock so the loser of a race skips.
        _ = check db->queryRow(`SELECT 1 FROM (SELECT pg_advisory_xact_lock(${MIGRATE_LOCK_KEY})) l`, int);
        string|sql:Error recorded = db->queryRow(`SELECT checksum FROM public.schema_version WHERE version = ${version}`);
        if recorded is string {
            if recorded != checksum {
                fail error(string `${script} was changed after it was applied; add a new script instead (forward-only)`);
            }
        } else if recorded is sql:NoRowsError {
            // The script file is trusted code shipped in the image, never user input: it is the one place
            // SQL text is executed as-is (it holds DDL and dollar-quoted bodies, which can't be bound).
            // `call`, not `execute`: execute asks the driver for generated keys, which appends RETURNING.
            sql:ProcedureCallResult result = check db->call(scriptQuery(content));
            check result.close();
            // Scripts switch to amplify_migrate with SET LOCAL ROLE; record the version as the runner.
            sql:ProcedureCallResult reset = check db->call(`RESET ROLE`);
            check reset.close();
            int elapsed = <int>(time:utcDiffSeconds(time:utcNow(), started) * 1000);
            _ = check db->execute(`
                INSERT INTO public.schema_version (version, kind, checksum, execution_ms)
                VALUES (${version}, ${kind}, ${checksum}, ${elapsed})`);
            applied = true;
        } else {
            fail recorded;
        }
        check commit;
    }
    if applied {
        summary.applied.push(script);
        log:printInfo(string `Applied ${kind} ${script}`);
    } else {
        summary.skipped += 1;
    }
}

# Wraps a trusted script file as a query with no parameters.
#
# + content - Script text
# + return - The query
function scriptQuery(string content) returns sql:ParameterizedCallQuery {
    sql:ParameterizedCallQuery query = ``;
    query.strings = [content].cloneReadOnly();
    return query;
}

# Sets LOGIN passwords for the app roles. The password is a bind parameter; the database function
# quotes it with format(%L). Empty secrets are skipped.
#
# + db - Client connected as the bootstrap admin
# + passwords - Role name to password
# + return - An error on failure
public function setRolePasswords(postgresql:Client db, map<string> passwords) returns error? {
    foreach [string, string] [role, password] in passwords.entries() {
        if password.length() == 0 {
            log:printInfo(string `No password configured for ${role}; left unchanged`);
            continue;
        }
        _ = check db->queryRow(`SELECT 1 FROM (SELECT public.amplify_set_login_password(${role}, ${password})) p`, int);
        log:printInfo(string `Password set for ${role}`);
    }
}
