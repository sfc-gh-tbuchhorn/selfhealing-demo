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
    dbt_proj          STRING;
    events_res        RESULTSET;
    in_flight_branch  STRING DEFAULT NULL;
BEGIN
    -- Pull latest commits from GitHub (including merged main)
    ALTER GIT REPOSITORY SELFHEALING_PROD.CONFIG.SELFHEALING_REPO FETCH;

    -- Resolve the dbt project name from CONFIG.SETTINGS (same key the setup
    -- sequence populates), so this always matches the project the tasks use.
    -- MAX() returns a single NULL row when the key is absent (avoids a
    -- no-data error); fall back to the registry default if unset.
    SELECT MAX(value) INTO :dbt_proj
    FROM SELFHEALING_PROD.CONFIG.SETTINGS
    WHERE key = 'dbt_project';

    IF (dbt_proj IS NULL) THEN
        dbt_proj := 'PLATFORM_REGISTRY.DBT.SELFHEALING';
    END IF;

    -- Redeploy PROD dbt project — always reflects exact state of main.
    -- The dbt project lives in the repo's dbt/ subdirectory (dbt_project.yml
    -- must be at the FROM path root), so point at branches/main/dbt/.
    EXECUTE IMMEDIATE
        'CREATE OR REPLACE DBT PROJECT ' || dbt_proj ||
        ' FROM @SELFHEALING_PROD.CONFIG.SELFHEALING_REPO/branches/main/dbt/';

    -- CREATE OR REPLACE resets ownership to the creating role (ACCOUNTADMIN).
    -- Re-grant ownership to the pipeline role so RUN_DEV_TEST (which runs as
    -- SELFHEALING_PIPELINE) can EXECUTE the project, and so GENERATE_AND_PREP
    -- (also SELFHEALING_PIPELINE) can CREATE OR REPLACE it for in-flight PRs.
    EXECUTE IMMEDIATE
        'GRANT OWNERSHIP ON DBT PROJECT ' || dbt_proj ||
        ' TO ROLE SELFHEALING_PIPELINE COPY CURRENT GRANTS';

    -- If there is already a PR_OPEN event on a feature branch (i.e. a schema
    -- change is in-flight), immediately redeploy the project from that branch.
    -- Without this, SYNC_FROM_MAIN would clobber the feature-branch project
    -- and RUN_DEV_TEST would fail against the stale main-branch version.
    SELECT MAX(branch_name) INTO :in_flight_branch
    FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
    WHERE pipeline_status = 'PR_OPEN'
      AND branch_name IS NOT NULL;

    IF (in_flight_branch IS NOT NULL) THEN
        EXECUTE IMMEDIATE
            'CREATE OR REPLACE DBT PROJECT ' || dbt_proj ||
            ' FROM @SELFHEALING_PROD.CONFIG.SELFHEALING_REPO/branches/"'
            || in_flight_branch || '"/dbt/';
        EXECUTE IMMEDIATE
            'GRANT OWNERSHIP ON DBT PROJECT ' || dbt_proj ||
            ' TO ROLE SELFHEALING_PIPELINE COPY CURRENT GRANTS';
    END IF;

    -- Advance SCHEMA_REGISTRY + mark resolved for every event on this branch.
    -- Delegates to RESOLVE_EVENT so all four change types are handled with a
    -- single, shared implementation (NEW_COLUMN insert, COLUMN_DROP delete,
    -- TYPE_CHANGE update, NEW_TABLE insert-all).
    -- Use a RESULTSET (binds :pr_branch at assignment) rather than a CURSOR
    -- with a bind variable — a FOR-loop over a bind-cursor does not bind the
    -- parameter and fails with "Bind variable :pr_branch not set".
    events_res := (
        SELECT event_id
        FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        WHERE branch_name = :pr_branch
          AND pipeline_status <> 'RESOLVED'
    );
    FOR rec IN events_res DO
        -- Assign the loop column to a local var and bind it — a loop
        -- variable cannot be referenced directly (rec.event_id) as a CALL
        -- argument ("invalid identifier 'REC.EVENT_ID'").
        LET v_event_id STRING := rec.event_id;
        CALL SELFHEALING_PROD.CONFIG.RESOLVE_EVENT(:v_event_id);
    END FOR;

    RETURN 'Synced from main and resolved branch: ' || :pr_branch;
END;
$$;

GRANT USAGE ON PROCEDURE SELFHEALING_PROD.CONFIG.SYNC_FROM_MAIN(VARCHAR)
  TO ROLE SELFHEALING_PIPELINE;

-- Grant read access to the git repository for the pipeline role.
-- READ on the repo + USAGE on its API integration are BOTH required: the
-- pipeline-role tasks (GENERATE_AND_PREP) read the repo / CREATE DBT PROJECT
-- from it, and that access is evaluated against the executing (task) role.
GRANT READ ON GIT REPOSITORY SELFHEALING_PROD.CONFIG.SELFHEALING_REPO
  TO ROLE SELFHEALING_PIPELINE;
GRANT USAGE ON INTEGRATION GITHUB_GIT_API_INTEGRATION
  TO ROLE SELFHEALING_PIPELINE;
