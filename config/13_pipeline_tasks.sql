-- =============================================================
-- 13_pipeline_tasks.sql
-- Core pipeline task — works on trial and full accounts.
--
-- PIPELINE_ROOT polls for PENDING schema change events every
-- 5 minutes. If a PENDING event exists it calls
-- GENERATE_ARTIFACT_CODE to generate updated dbt models.
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

ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.PIPELINE_ROOT SUSPEND;

CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.PIPELINE_ROOT
    WAREHOUSE = SELFHEALING_WH
    SCHEDULE  = '5 MINUTE'
AS
DECLARE
    v_event_id VARCHAR;
BEGIN
    SELECT event_id INTO :v_event_id
    FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
    WHERE pipeline_status = 'PENDING'
    ORDER BY detected_at
    LIMIT 1;

    IF (v_event_id IS NOT NULL) THEN
        CALL SELFHEALING_PROD.CONFIG.GENERATE_ARTIFACT_CODE(:v_event_id);
    END IF;
END;

ALTER TASK SELFHEALING_PROD.CONFIG.PIPELINE_ROOT RESUME;
