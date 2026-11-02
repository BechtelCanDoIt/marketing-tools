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


-- uuidv7() for PostgreSQL before 18 (ADR-044).
--
-- PostgreSQL 18 ships a native uuidv7(). Earlier servers (staging runs 17) don't, and V002-V008 use it as a column
-- default. The migrate runner runs this file before the first script, only when the server has no native function,
-- so no migration changes and nothing here runs on 18. When the file is applied by hand (the runner isn't used),
-- run it first, as the login user, with the schema first on the search_path.
--
-- The function is the usual SQL form: a v4 random uuid whose first 48 bits are replaced by the Unix time in
-- milliseconds and whose version bits are set to 7. It is time-ordered like the native one but does not add the
-- native sub-millisecond counter, so two ids made in the same millisecond are ordered randomly, not by creation.
-- It is created in the current schema (the one the runner put first on the search_path), and each table binds it by
-- OID when its default is created, so upgrading the server to 18 later leaves existing tables working.

DO $compat$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.proname = 'uuidv7' AND p.pronamespace = 'pg_catalog'::regnamespace) THEN
        RAISE NOTICE 'native uuidv7() found; nothing to install';
        RETURN;
    END IF;
    IF current_schema() IS NULL THEN
        RAISE EXCEPTION 'No schema on the search_path to create uuidv7() in';
    END IF;
    EXECUTE $def$
        CREATE OR REPLACE FUNCTION uuidv7() RETURNS uuid
            LANGUAGE sql VOLATILE PARALLEL SAFE
        AS $body$
            SELECT encode(
                set_bit(
                    set_bit(
                        overlay(uuid_send(gen_random_uuid())
                                PLACING substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
                                FROM 1 FOR 6),
                        52, 1),
                    53, 1),
                'hex')::uuid
        $body$
    $def$;
END
$compat$;
