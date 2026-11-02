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

-- D3: can the single login user run Amplify with group roles? Run once per environment, connected as that
-- user (staging `amplify_stg_user`, production its own name). Read-only. Every row should say OK.
-- The schema is the one named after the login user.

SELECT 'login user' AS item, current_user::text AS value, 'info' AS result
UNION ALL
SELECT 'role exists: ' || r, coalesce((SELECT 'yes' FROM pg_roles WHERE rolname = r), 'no'),
       CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN 'OK' ELSE 'MISSING' END
FROM unnest(ARRAY['amplify_migrate', 'amplify_api', 'amplify_jobs', 'amplify_readonly']) AS r
UNION ALL
SELECT 'login user can SET ROLE ' || r, 'SET',
       CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) AND pg_has_role(current_user, r, 'SET')
            THEN 'OK' ELSE 'GRANT ' || r || ' TO ' || current_user || ' WITH SET TRUE' END
FROM unnest(ARRAY['amplify_migrate', 'amplify_api', 'amplify_jobs', 'amplify_readonly']) AS r
UNION ALL
SELECT 'schema named after the login user exists', current_user::text,
       CASE WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = current_user) THEN 'OK'
            ELSE 'CREATE SCHEMA ' || current_user END
UNION ALL
SELECT 'amplify_migrate can create in that schema', 'CREATE',
       CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'amplify_migrate')
                 AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = current_user)
                 AND has_schema_privilege('amplify_migrate', current_user::text, 'CREATE')
            THEN 'OK'
            WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = current_user AND nspowner = current_user::regrole)
            THEN 'OK, V001 grants it (the login user owns the schema)'
            ELSE 'GRANT USAGE, CREATE ON SCHEMA ' || current_user || ' TO amplify_migrate' END
UNION ALL
SELECT 'extension ' || e, coalesce((SELECT extversion FROM pg_extension WHERE extname = e), 'not installed'),
       CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = e) THEN 'OK'
            ELSE 'CREATE EXTENSION ' || e END
FROM unnest(ARRAY['citext', 'pg_trgm']) AS e
UNION ALL
SELECT 'server version', current_setting('server_version_num'),
       CASE WHEN current_setting('server_version_num')::int >= 180000 THEN 'OK' ELSE 'NEEDS PG 18 (uuidv7)' END;
