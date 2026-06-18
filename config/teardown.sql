-- =============================================================
-- teardown.sql
-- Removes all objects created by the self-healing demo.
-- Run as ACCOUNTADMIN. Safe to run on trial or full accounts —
-- every statement uses IF EXISTS so missing objects are skipped.
--
--   snow sql -c <connection> -f config/teardown.sql
-- =============================================================

USE ROLE ACCOUNTADMIN;

-- ── 1. Suspend tasks before dropping (best effort) ────────────
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.PIPELINE_FINALIZER     SUSPEND;
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.COMMIT_AND_MR          SUSPEND;
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.RUN_DEV_TEST           SUSPEND;
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.PIPELINE_ROOT          SUSPEND;
ALTER TASK IF EXISTS SELFHEALING_PROD.CONFIG.SCHEMA_DRIFT_DETECTOR  SUSPEND;

-- ── 2. Drop databases (removes schemas, tables, procs, tasks, ─
--       the GITHUB_PAT secret, git repo, and the DBT PROJECT) ──
DROP DATABASE IF EXISTS SELFHEALING_DEV;
DROP DATABASE IF EXISTS SELFHEALING_PROD;

-- ── 3. Drop warehouse ─────────────────────────────────────────
DROP WAREHOUSE IF EXISTS SELFHEALING_WH;

-- ── 4. Drop the agent role ────────────────────────────────────
DROP ROLE IF EXISTS SELFHEALING_AGENT;

-- ── 5. Account-level integrations (full version only — trial ──
--       never created these, so they are skipped harmlessly) ──
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS GITHUB_EAI;
DROP API INTEGRATION IF EXISTS GITHUB_GIT_API_INTEGRATION;

-- ── 6. Verify nothing remains ─────────────────────────────────
SHOW DATABASES LIKE 'SELFHEALING_%';
SHOW WAREHOUSES LIKE 'SELFHEALING_WH';
SHOW ROLES LIKE 'SELFHEALING_AGENT';
