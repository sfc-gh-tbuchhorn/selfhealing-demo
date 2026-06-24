-- =============================================================
-- teardown.sql
-- Removes all objects created by the self-healing demo.
-- Run as ACCOUNTADMIN. Safe to run on trial or full accounts,
-- with one exception: the ALTER POSTGRES INSTANCE statement in
-- section 2 is full-version only — trial users can ignore the
-- error it produces (SELFHEALING_PG does not exist on trial).
--
--   snow sql -c <connection> -f config/teardown.sql
-- =============================================================

USE ROLE ACCOUNTADMIN;

-- ── 1. Tasks are dropped automatically when SELFHEALING_PROD is ─
--       dropped below (tasks live inside the database). No explicit
--       suspend is needed. Stop the Openflow connector before running
--       this script to prevent CDC writes during teardown.


-- ── 2. Detach network policy from Snowflake Postgres instance ──
--       Full version only — trial users skip these two lines.
--       Must happen before dropping SELFHEALING_PROD, which contains
--       the PG_INGRESS_RULE network rule referenced by the policy.
--       ALTER POSTGRES INSTANCE has no IF EXISTS; it errors cleanly
--       if SELFHEALING_PG does not exist (trial) and can be ignored.
ALTER POSTGRES INSTANCE SELFHEALING_PG UNSET NETWORK_POLICY;
DROP NETWORK POLICY IF EXISTS SELFHEALING_PG_POLICY;

-- ── 3. Drop databases (removes schemas, tables, procs, tasks, ─
--       the GITHUB_PAT secret, git repo, and the DBT PROJECT) ──
DROP DATABASE IF EXISTS SELFHEALING_DEV;
DROP DATABASE IF EXISTS SELFHEALING_PROD;

-- ── 4. Drop warehouse ─────────────────────────────────────────
DROP WAREHOUSE IF EXISTS SELFHEALING_WH;

-- ── 5. Drop the agent role ────────────────────────────────────
DROP ROLE IF EXISTS SELFHEALING_PIPELINE;

-- ── 6. Account-level integrations (full version only — trial ──
--       never created these, so they are skipped harmlessly) ──
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS GITHUB_EAI;
DROP API INTEGRATION IF EXISTS GITHUB_GIT_API_INTEGRATION;

-- ── 7. Verify nothing remains ─────────────────────────────────
SHOW DATABASES LIKE 'SELFHEALING_%';
SHOW WAREHOUSES LIKE 'SELFHEALING_WH';
SHOW ROLES LIKE 'SELFHEALING_PIPELINE';
