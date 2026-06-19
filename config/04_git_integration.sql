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
    ALLOWED_AUTHENTICATION_SECRETS = (SELFHEALING_PROD.CONFIG.GITHUB_GIT_CREDENTIALS)
    ENABLED                  = TRUE;

-- -----------------------------------------------------------
-- Git credentials secret (PASSWORD type, required for GIT REPOSITORY).
-- Created from env vars in the setup sequence (inline `snow sql -q`,
-- which gets shell interpolation — a `-f` file like this one cannot
-- read $GITHUB_PAT). See README "Full account setup". This file
-- assumes SELFHEALING_PROD.CONFIG.GITHUB_GIT_CREDENTIALS already exists.
-- -----------------------------------------------------------

-- -----------------------------------------------------------
-- Git Repository object — mirrors sfc-gh-tbuchhorn/selfhealing_demo
-- Files accessible at @SELFHEALING_REPO/branches/<branch>/path
-- -----------------------------------------------------------
CREATE OR REPLACE GIT REPOSITORY SELFHEALING_PROD.CONFIG.SELFHEALING_REPO
    API_INTEGRATION  = GITHUB_GIT_API_INTEGRATION
    GIT_CREDENTIALS  = SELFHEALING_PROD.CONFIG.GITHUB_GIT_CREDENTIALS
    ORIGIN           = 'https://github.com/sfc-gh-tbuchhorn/selfhealing-demo';

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
DECLARE
    events_cur CURSOR FOR
        SELECT event_id
        FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        WHERE branch_name = :pr_branch
          AND pipeline_status <> 'RESOLVED';
BEGIN
    -- Pull latest commits from GitHub (including merged main)
    ALTER GIT REPOSITORY SELFHEALING_PROD.CONFIG.SELFHEALING_REPO FETCH;

    -- Redeploy PROD dbt project — always reflects exact state of main.
    -- The dbt project lives in the repo's dbt/ subdirectory (dbt_project.yml
    -- must be at the FROM path root), so point at branches/main/dbt/.
    CREATE OR REPLACE DBT PROJECT PLATFORM_REGISTRY.DBT.SELFHEALING
        FROM @SELFHEALING_PROD.CONFIG.SELFHEALING_REPO/branches/main/dbt/;

    -- Advance SCHEMA_REGISTRY + mark resolved for every event on this branch.
    -- Delegates to RESOLVE_EVENT so all four change types are handled with a
    -- single, shared implementation (NEW_COLUMN insert, COLUMN_DROP delete,
    -- TYPE_CHANGE update, NEW_TABLE insert-all).
    FOR rec IN events_cur DO
        CALL SELFHEALING_PROD.CONFIG.RESOLVE_EVENT(rec.event_id);
    END FOR;

    RETURN 'Synced from main and resolved branch: ' || :pr_branch;
END;
$$;

GRANT USAGE ON PROCEDURE SELFHEALING_PROD.CONFIG.SYNC_FROM_MAIN(VARCHAR)
  TO ROLE SELFHEALING_PIPELINE;

-- Grant read access to the git repository for agent role
GRANT READ ON GIT REPOSITORY SELFHEALING_PROD.CONFIG.SELFHEALING_REPO
  TO ROLE SELFHEALING_PIPELINE;
