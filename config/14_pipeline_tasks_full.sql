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

-- Full-version grant: agent role needs to create the DEV test dbt project.
-- (Not applied in 02_rbac.sql because PLATFORM_REGISTRY does not exist on trial.)
GRANT CREATE DBT PROJECT ON SCHEMA PLATFORM_REGISTRY.DBT
  TO ROLE SELFHEALING_AGENT;

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
    EXECUTE DBT PROJECT PLATFORM_REGISTRY.DBT.SELFHEALING_TEST
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
