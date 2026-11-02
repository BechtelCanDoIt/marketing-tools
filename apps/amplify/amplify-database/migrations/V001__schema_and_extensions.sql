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

-- V001: the schema and the extensions (phase1-data-model, B18).
--
-- The database gives Amplify one login user and one schema named after it (staging `amplify_stg_user`,
-- production its own name). There are no roles: the login user owns every object and every component connects
-- as it (ADR-043). This script creates no schema and no role; it checks that the schema exists and that the two
-- extensions are installed.
--
-- The runner connects as the login user and puts the schema first on the `search_path` (`dbSchema`, default the
-- user name), so no script names a schema and every table is `<context>_<name>`. `SECURITY DEFINER` functions
-- use `SET search_path FROM CURRENT`, which captures that list.

DO $check$
BEGIN
    IF current_schema() IS NULL THEN
        RAISE EXCEPTION 'No schema on the search_path: create the schema named after the login user (%) or set dbSchema',
            current_user;
    END IF;
END
$check$;

-- Required extensions (B18). Both are trusted, so they work on managed Postgres without superuser; when the DBA
-- already installed them this does nothing.
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
