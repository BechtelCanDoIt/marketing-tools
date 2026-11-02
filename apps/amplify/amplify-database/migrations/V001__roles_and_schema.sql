-- Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
--
-- WSO2 LLC. licenses this file to you under the Apache License,
-- Version 2.0 (the "License"); you may not use this file except
-- in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.

-- V001: check the single-user setup, grant the roles access to the schema, extensions (phase1-data-model ›
-- Database users and grants, B12, B18).
--
-- The database gives Amplify one login user and one schema named after it (staging `amplify_stg_user`,
-- production its own name). The DBA creates the four NOLOGIN group roles `amplify_migrate`, `amplify_api`,
-- `amplify_jobs` and `amplify_readonly`, and grants them to the login user WITH SET TRUE. Run
-- `checks/d3_single_user_roles.sql` first; it lists what is missing. This script creates no roles and no
-- schema.
--
-- The runner connects as the login user and sets `search_path` to that schema before each script, so no script
-- names a schema: `current_schema()` is the target and every table is `<context>_<name>`. Later scripts start
-- with `SET LOCAL ROLE amplify_migrate`, so amplify_migrate owns every object and app roles never own anything
-- (they can't ALTER or DROP). The services connect as the same login user and `SET ROLE` to their own role
-- (`dbRole`), so the grants in V002-V020 still separate api, jobs and readonly.
--
-- No passwords live here or in the runner: the roles stay NOLOGIN.

DO $check$
DECLARE
    v_schema text := current_schema();
    v_role   text;
BEGIN
    IF v_schema IS NULL THEN
        RAISE EXCEPTION 'No schema on the search_path: create the schema named after the login user (%) or set dbSchema',
            current_user;
    END IF;
    FOREACH v_role IN ARRAY ARRAY['amplify_migrate', 'amplify_api', 'amplify_jobs', 'amplify_readonly'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            RAISE EXCEPTION 'Role % does not exist: the DBA creates it (CREATE ROLE % NOLOGIN)', v_role, v_role;
        END IF;
        IF NOT pg_has_role(current_user, v_role, 'SET') THEN
            RAISE EXCEPTION '% cannot SET ROLE %: GRANT % TO % WITH SET TRUE', current_user, v_role, v_role, current_user;
        END IF;
    END LOOP;
    -- Only the owner of the schema (or a role with grant option) can hand out these rights.
    EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO amplify_migrate', v_schema);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO amplify_api, amplify_jobs, amplify_readonly', v_schema);
END
$check$;

-- Required extensions (B18). Both are trusted, so they work on managed Postgres without superuser; when the DBA
-- already installed them this does nothing.
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
