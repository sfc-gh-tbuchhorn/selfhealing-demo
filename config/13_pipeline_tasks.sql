-- =============================================================
-- 10_pipeline_tasks.sql
-- Task DAG — fully Snowflake-native pipeline.
-- No local machine required after initial stage setup.
--
-- DAG structure:
--
--   PIPELINE_ROOT (5 min, WHEN pending events exist)
--     └─ calls GENERATE_AND_PREP()
--     └─ triggers: RUN_DEV_TEST
--          └─ calls EXECUTE DBT PROJECT SELFHEALING_TEST in DEV
--          └─ triggers (on success): COMMIT_AND_MR
--               └─ calls COMMIT_TO_GITHUB()
--   PIPELINE_FINALIZER (finalizer for PIPELINE_ROOT, always runs)
--     └─ calls HANDLE_TEST_FAILURE()
--        reverts stage + marks FAILED if stuck in TESTING state
--
-- Status guarantees:
--   • COMMIT_AND_MR only fires if dbt PASS → GitHub PR opened
--   • PIPELINE_FINALIZER always fires → reverts files on failure
--   • Filesystem (stage) always clean after any run
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

-- Suspend existing tasks before recreating
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.COMMIT_AND_MR        SUSPEND;
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.RUN_DEV_TEST         SUSPEND;
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.PIPELINE_FINALIZER   SUSPEND;
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.PIPELINE_ROOT        SUSPEND;

-- -----------------------------------------------------------
-- ROOT: runs every 5 minutes, skips if nothing to process
-- -----------------------------------------------------------
CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.PIPELINE_ROOT
    WAREHOUSE = SELFHEALING_WH
    SCHEDULE  = '5 MINUTE'
AS
    CALL SELFHEALING_PROD.CONFIG.GENERATE_AND_PREP();

-- -----------------------------------------------------------
-- RUN_DEV_TEST: execute dbt against SELFHEALING_DEV
-- Runs all models — validates accumulated changes together
-- -----------------------------------------------------------
CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.RUN_DEV_TEST
    WAREHOUSE = SELFHEALING_WH
    AFTER     SELFHEALING_PROD.CONFIG.PIPELINE_ROOT
AS
    EXECUTE DBT PROJECT PLATFORM_REGISTRY.DBT.SELFHEALING_TEST
        ARGS = 'run --vars "{db_name: SELFHEALING_DEV}" --target prod';

-- -----------------------------------------------------------
-- COMMIT_AND_MR: open GitHub PR only after dbt passes
-- -----------------------------------------------------------
CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.COMMIT_AND_MR
    WAREHOUSE = SELFHEALING_WH
    AFTER     SELFHEALING_PROD.CONFIG.RUN_DEV_TEST
AS
    CALL SELFHEALING_PROD.CONFIG.COMMIT_TO_GITHUB();

-- -----------------------------------------------------------
-- PIPELINE_FINALIZER: always runs — reverts on failure
-- -----------------------------------------------------------
CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.PIPELINE_FINALIZER
    WAREHOUSE = SELFHEALING_WH
    FINALIZE  = SELFHEALING_PROD.CONFIG.PIPELINE_ROOT
AS
    CALL SELFHEALING_PROD.CONFIG.HANDLE_TEST_FAILURE();

-- -----------------------------------------------------------
-- Resume tasks (leaf-to-root order required by Snowflake)
-- -----------------------------------------------------------
ALTER TASK SELFHEALING_PROD.CONFIG.PIPELINE_FINALIZER RESUME;
ALTER TASK SELFHEALING_PROD.CONFIG.COMMIT_AND_MR      RESUME;
ALTER TASK SELFHEALING_PROD.CONFIG.RUN_DEV_TEST       RESUME;
ALTER TASK SELFHEALING_PROD.CONFIG.PIPELINE_ROOT      RESUME;
