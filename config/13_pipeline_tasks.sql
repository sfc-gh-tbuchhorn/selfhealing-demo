-- =============================================================
-- 13_pipeline_tasks.sql
-- Core pipeline task — works on trial and full accounts.
--
-- PIPELINE_ROOT polls for PENDING schema change events every
-- 5 minutes and calls GENERATE_NEXT_PENDING which finds the
-- oldest PENDING event and runs GENERATE_ARTIFACT_CODE.
-- No EAI or PLATFORM_REGISTRY required.
--
-- After this task fires, run materialise_in_dev.py locally
-- to validate in DEV and open the PR.
--
-- On full accounts, also run 14_pipeline_tasks_full.sql to
-- automate the DEV test and GitHub PR steps inside Snowflake.
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.PIPELINE_ROOT
    WAREHOUSE = SELFHEALING_WH
    SCHEDULE  = '5 MINUTE'
AS
    CALL SELFHEALING_PROD.CONFIG.GENERATE_NEXT_PENDING();

ALTER TASK SELFHEALING_PROD.CONFIG.PIPELINE_ROOT RESUME;
