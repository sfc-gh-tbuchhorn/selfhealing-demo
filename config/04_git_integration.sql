-- =============================================================
-- 12_git_integration.sql
-- Snowflake native Git integration — makes GitHub main branch
-- the single source of truth for all dbt code.
--
-- Run once as ACCOUNTADMIN.
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

-- -----------------------------------------------------------
-- API Integration for Git HTTPS access
-- This is a different object type from GITHUB_EAI (which is
-- an External Access Integration for outbound HTTP calls).
-- This one enables Snowflake to clone/fetch the Git repo.
-- -----------------------------------------------------------
CREATE OR REPLACE API INTEGRATION GITHUB_GIT_API_INTEGRATION
    API_PROVIDER             = git_https_api
    API_ALLOWED_PREFIXES     = ('https://github.com/sfc-gh-tbuchhorn')
    ALLOWED_AUTHENTICATION_SECRETS = (SELFHEALING_PROD.CONFIG.GITHUB_PAT)
    ENABLED                  = TRUE;

-- -----------------------------------------------------------
-- Git credentials secret (PASSWORD type required for GIT REPOSITORY)
-- Username = GitHub username; password = GitHub PAT.
-- Populate after running:
--   ALTER SECRET SELFHEALING_PROD.CONFIG.GITHUB_GIT_CREDENTIALS
--     SET USERNAME = 'sfc-gh-tbuchhorn'
--         PASSWORD = '<your_pat_here>';
-- -----------------------------------------------------------
CREATE SECRET IF NOT EXISTS SELFHEALING_PROD.CONFIG.GITHUB_GIT_CREDENTIALS
    TYPE     = PASSWORD
    USERNAME = 'sfc-gh-tbuchhorn'
    PASSWORD = 'REPLACE_WITH_PAT';

-- -----------------------------------------------------------
-- Git Repository object — mirrors sfc-gh-tbuchhorn/selfhealing_demo
-- Files accessible at @SELFHEALING_REPO/branches/<branch>/path
-- -----------------------------------------------------------
CREATE OR REPLACE GIT REPOSITORY SELFHEALING_PROD.CONFIG.SELFHEALING_REPO
    API_INTEGRATION  = GITHUB_GIT_API_INTEGRATION
    GIT_CREDENTIALS  = SELFHEALING_PROD.CONFIG.GITHUB_GIT_CREDENTIALS
    ORIGIN           = 'https://github.com/sfc-gh-tbuchhorn/selfhealing_demo';

-- Initial fetch — pulls all branches from remote
ALTER GIT REPOSITORY SELFHEALING_PROD.CONFIG.SELFHEALING_REPO FETCH;

-- -----------------------------------------------------------
-- SYNC_FROM_MAIN
-- Called by the GitHub Action after a schema-change PR is merged.
-- Fetches latest main, redeploys PROD dbt project from it,
-- advances SCHEMA_REGISTRY, and marks the event RESOLVED.
-- EXECUTE AS OWNER: needs CREATE DBT PROJECT + DML on CONFIG tables.
-- -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.SYNC_FROM_MAIN(pr_branch VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    -- Pull latest commits from GitHub (including merged main)
    ALTER GIT REPOSITORY SELFHEALING_PROD.CONFIG.SELFHEALING_REPO FETCH;

    -- Redeploy PROD dbt project — always reflects exact state of main
    CREATE OR REPLACE DBT PROJECT PLATFORM_REGISTRY.DBT.SELFHEALING
        FROM @SELFHEALING_PROD.CONFIG.SELFHEALING_REPO/branches/main/;

    -- Advance SCHEMA_REGISTRY for any NEW_COLUMN events on this branch
    INSERT INTO SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY (table_schema, table_name, column_name, data_type)
        SELECT e.table_schema, e.table_name, e.column_name, e.new_data_type
        FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS e
        WHERE e.branch_name  = :pr_branch
          AND e.change_type  = 'NEW_COLUMN'
          AND e.new_data_type IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY r
              WHERE r.table_schema = e.table_schema
                AND r.table_name   = e.table_name
                AND r.column_name  = e.column_name
          );

    -- Mark event resolved
    UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
    SET    status          = 'RESOLVED',
           pipeline_status = 'RESOLVED',
           resolved_at     = CURRENT_TIMESTAMP()
    WHERE  branch_name = :pr_branch;

    RETURN 'Synced from main and resolved branch: ' || :pr_branch;
END;
$$;

GRANT USAGE ON PROCEDURE SELFHEALING_PROD.CONFIG.SYNC_FROM_MAIN(VARCHAR)
  TO ROLE SELFHEALING_AGENT;

-- Grant read access to the git repository for agent role
GRANT READ ON GIT REPOSITORY SELFHEALING_PROD.CONFIG.SELFHEALING_REPO
  TO ROLE SELFHEALING_AGENT;
