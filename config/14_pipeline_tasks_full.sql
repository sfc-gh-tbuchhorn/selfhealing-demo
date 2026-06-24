-- =============================================================
-- 14_pipeline_tasks_full.sql
-- Full pipeline task DAG — requires EAI and PLATFORM_REGISTRY.
-- Run AFTER 09_pipeline_procs.sql and 13_pipeline_tasks.sql.
--
-- Extends PIPELINE_ROOT with:
--   RUN_DEV_TEST  — runs dbt against SELFHEALING_DEV clone
--   COMMIT_AND_MR — opens GitHub PR after dbt passes
--   PIPELINE_FINALIZER — posts failure comment if dbt fails
--
-- Full automated flow (no local machine required after setup):
--   PIPELINE_ROOT (generates code)
--     └─ RUN_DEV_TEST (dbt run in DEV)
--          └─ COMMIT_AND_MR (open PR + post CI comment)
--   PIPELINE_FINALIZER (always runs — handles failures)
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

-- Full-version grant: the pipeline role creates the DEV-test dbt project
-- (GENERATE_AND_PREP) in SELFHEALING_PROD.CONFIG. No PLATFORM_REGISTRY needed.
GRANT CREATE DBT PROJECT ON SCHEMA SELFHEALING_PROD.CONFIG
  TO ROLE SELFHEALING_PIPELINE;

-- Suspend child tasks before recreating root
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.COMMIT_AND_MR      SUSPEND;
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.RUN_DEV_TEST        SUSPEND;
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.PIPELINE_FINALIZER  SUSPEND;

CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.PIPELINE_ROOT
    WAREHOUSE = SELFHEALING_WH
    SCHEDULE  = '5 MINUTE'
AS
    CALL SELFHEALING_PROD.CONFIG.GENERATE_AND_PREP();

-- -----------------------------------------------------------
-- RUN_DEV_TEST: dbt run against SELFHEALING_DEV clone
-- Only executes when GENERATE_AND_PREP has opened a PR (event in
-- PR_OPEN state). EXECUTE DBT PROJECT is not valid inside a SQL
-- scripting BEGIN...END block, so the guard lives in a thin Python
-- wrapper procedure that calls it via session.sql().
-- -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.RUN_DEV_TEST_IF_OPEN()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS $$
DBT_PROJECT = 'SELFHEALING_PROD.CONFIG.SELFHEALING'

def run(session):
    rows = session.sql("""
        SELECT COUNT(*) AS n
        FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        WHERE pipeline_status = 'PR_OPEN'
    """).collect()

    if rows[0]['N'] == 0:
        return 'No PR_OPEN events — skipping dbt test'

    session.sql(
        f"EXECUTE DBT PROJECT {DBT_PROJECT}"
        f" ARGS = 'run --vars \"{{db_name: SELFHEALING_DEV}}\" --target dev'"
    ).collect()
    return 'dbt test complete'
$$;

GRANT USAGE ON PROCEDURE SELFHEALING_PROD.CONFIG.RUN_DEV_TEST_IF_OPEN()
  TO ROLE SELFHEALING_PIPELINE;

CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.RUN_DEV_TEST
    WAREHOUSE = SELFHEALING_WH
    AFTER     SELFHEALING_PROD.CONFIG.PIPELINE_ROOT
AS
    CALL SELFHEALING_PROD.CONFIG.RUN_DEV_TEST_IF_OPEN();

-- -----------------------------------------------------------
-- COMMIT_AND_MR: open GitHub PR after dbt passes
-- -----------------------------------------------------------
CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.COMMIT_AND_MR
    WAREHOUSE = SELFHEALING_WH
    AFTER     SELFHEALING_PROD.CONFIG.RUN_DEV_TEST
AS
    CALL SELFHEALING_PROD.CONFIG.COMMIT_TO_GITHUB();

-- -----------------------------------------------------------
-- PIPELINE_FINALIZER: always runs — posts failure comment
-- -----------------------------------------------------------
CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.PIPELINE_FINALIZER
    WAREHOUSE = SELFHEALING_WH
    FINALIZE  = SELFHEALING_PROD.CONFIG.PIPELINE_ROOT
AS
    CALL SELFHEALING_PROD.CONFIG.HANDLE_TEST_FAILURE();

-- Resume leaf-to-root
ALTER TASK SELFHEALING_PROD.CONFIG.PIPELINE_FINALIZER  RESUME;
ALTER TASK SELFHEALING_PROD.CONFIG.COMMIT_AND_MR       RESUME;
ALTER TASK SELFHEALING_PROD.CONFIG.RUN_DEV_TEST        RESUME;
ALTER TASK SELFHEALING_PROD.CONFIG.PIPELINE_ROOT       RESUME;
