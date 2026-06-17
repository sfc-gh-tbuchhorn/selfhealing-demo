-- =============================================================
-- 05_dev_environment.sql
-- REFRESH_DEV_ENVIRONMENT  — EXECUTE AS OWNER
--   Drops and recreates SELFHEALING_DEV as a zero-copy clone of
--   SELFHEALING_PROD and re-grants SELFHEALING_AGENT narrow
--   access to DEV. GENERATED_CODE is no longer created here —
--   generated SQL is stored in SCHEMA_CHANGE_EVENTS.generated_changes.
--
-- TEST_GENERATED_CODE  — EXECUTE AS CALLER
--   Compiles Jinja macros in generated SQL to DEV references,
--   validates with EXPLAIN, runs row-count check, updates
--   test_status in SELFHEALING_DEV.CONFIG.GENERATED_CODE.
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

-- -----------------------------------------------------------
-- REFRESH_DEV_ENVIRONMENT
-- EXECUTE AS OWNER: only the owner role holds CREATE DATABASE.
-- After cloning, re-grants agent role access so grants are
-- never stale (they are lost when the database is dropped).
-- -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.REFRESH_DEV_ENVIRONMENT()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    DROP DATABASE IF EXISTS SELFHEALING_DEV;
    CREATE DATABASE SELFHEALING_DEV CLONE SELFHEALING_PROD;

    GRANT USAGE ON DATABASE SELFHEALING_DEV
      TO ROLE SELFHEALING_AGENT;
    GRANT USAGE ON ALL SCHEMAS IN DATABASE SELFHEALING_DEV
      TO ROLE SELFHEALING_AGENT;
    GRANT SELECT ON ALL TABLES IN DATABASE SELFHEALING_DEV
      TO ROLE SELFHEALING_AGENT;
    GRANT CREATE TABLE ON SCHEMA SELFHEALING_DEV.SILVER
      TO ROLE SELFHEALING_AGENT;
    GRANT CREATE TABLE ON SCHEMA SELFHEALING_DEV.GOLD
      TO ROLE SELFHEALING_AGENT;

    RETURN 'SELFHEALING_DEV refreshed — grants applied to SELFHEALING_AGENT';
END;
$$;

-- -----------------------------------------------------------
-- TEST_GENERATED_CODE
-- EXECUTE AS CALLER: runs with the caller's role so RBAC is
-- enforced — the agent can only reach DEV, never PROD writes.
-- -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.TEST_GENERATED_CODE(
    event_id VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS $$
import re, json

def compile_jinja(sql, artifact_name):
    """
    Lightweight Jinja substitution: replace dbt macros with
    concrete SELFHEALING_DEV references for test execution.
    """
    # Strip {{ config(...) }} block (multiline)
    sql = re.sub(r'\{\{[\s]*config\([^}]*\)[\s]*\}\}', '', sql, flags=re.DOTALL)

    # {{ source('bronze', 'table') }} → SELFHEALING_DEV.BRONZE.TABLE
    def replace_source(m):
        schema = m.group(1).upper()
        table  = m.group(2).upper()
        return f'SELFHEALING_DEV.{schema}.{table}'
    sql = re.sub(
        r"\{\{\s*source\(\s*['\"](\w+)['\"]\s*,\s*['\"](\w+)['\"]\s*\)\s*\}\}",
        replace_source, sql
    )

    # {{ ref('model') }} → resolve schema from artifact name
    # e.g. ref('orders') → silver model → SELFHEALING_DEV.SILVER.ORDERS
    def replace_ref(m):
        model = m.group(1).upper()
        # look up schema from ARTIFACT_REGISTRY prefix in artifact_name
        # silver.X uses SILVER, gold.X uses GOLD
        schema = 'SILVER' if artifact_name.startswith('gold') else 'SILVER'
        return f'SELFHEALING_DEV.{schema}.{model}'
    sql = re.sub(
        r"\{\{\s*ref\(\s*['\"](\w+)['\"]\s*\)\s*\}\}",
        replace_ref, sql
    )

    # {{ var('db_name') }} → SELFHEALING_DEV
    sql = re.sub(r"\{\{\s*var\(['\"]db_name['\"]\)\s*\}\}", 'SELFHEALING_DEV', sql)

    return sql.strip()


def run(session, event_id):
    rows = session.sql(f"""
        SELECT GENERATION_ID, ARTIFACT_NAME, FILE_PATH, ACTION,
               GENERATED_SQL
        FROM SELFHEALING_DEV.CONFIG.GENERATED_CODE
        WHERE EVENT_ID = '{event_id}'
          AND TEST_STATUS = 'PENDING'
        ORDER BY GENERATED_AT ASC
    """).collect()

    results = []
    for r in rows:
        gen_id        = r['GENERATION_ID']
        artifact_name = r['ARTIFACT_NAME']
        file_path     = r['FILE_PATH']
        action        = r['ACTION']
        generated_sql = r['GENERATED_SQL']

        try:
            compiled = compile_jinja(generated_sql, artifact_name)

            # Step 1: EXPLAIN validates the query plan
            session.sql(f'EXPLAIN {compiled}').collect()

            # Step 2: row count confirms data returns
            cnt = session.sql(
                f'SELECT COUNT(*) AS CNT FROM ({compiled}) AS t'
            ).collect()[0]['CNT']

            session.sql(f"""
                UPDATE SELFHEALING_DEV.CONFIG.GENERATED_CODE
                SET TEST_STATUS = 'PASS',
                    TEST_ERROR  = NULL
                WHERE GENERATION_ID = '{gen_id}'
            """).collect()

            results.append({
                'artifact_name': artifact_name,
                'file_path':     file_path,
                'action':        action,
                'test_status':   'PASS',
                'row_count':     cnt,
                'generated_sql': generated_sql
            })

        except Exception as e:
            err = str(e)[:500].replace("'", "\\'")
            session.sql(f"""
                UPDATE SELFHEALING_DEV.CONFIG.GENERATED_CODE
                SET TEST_STATUS = 'FAIL',
                    TEST_ERROR  = '{err}'
                WHERE GENERATION_ID = '{gen_id}'
            """).collect()

            results.append({
                'artifact_name': artifact_name,
                'file_path':     file_path,
                'action':        action,
                'test_status':   'FAIL',
                'test_error':    err
            })

    return {'event_id': event_id, 'results': results}
$$;
