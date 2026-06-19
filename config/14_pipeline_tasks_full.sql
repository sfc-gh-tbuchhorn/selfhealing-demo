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
-- -----------------------------------------------------------
CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.RUN_DEV_TEST
    WAREHOUSE = SELFHEALING_WH
    AFTER     SELFHEALING_PROD.CONFIG.PIPELINE_ROOT
AS
    -- Must match the project GENERATE_AND_PREP creates (= SETTINGS.dbt_project
    -- = $DBT_PROJECT). A task body can't read SETTINGS, so this name is fixed:
    -- keep $DBT_PROJECT = SELFHEALING_PROD.CONFIG.SELFHEALING for the full version.
    EXECUTE DBT PROJECT SELFHEALING_PROD.CONFIG.SELFHEALING
        ARGS = 'run --vars "{db_name: SELFHEALING_DEV}" --target prod';

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
