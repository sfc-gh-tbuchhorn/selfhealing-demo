-- =============================================================
-- 07_rbac.sql
-- SELFHEALING_AGENT role — read-only on SELFHEALING_PROD,
-- USAGE on stored procedures, full access to SELFHEALING_DEV
-- re-granted dynamically by REFRESH_DEV_ENVIRONMENT().
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE ROLE IF NOT EXISTS SELFHEALING_AGENT;

-- ── PROD: read-only ───────────────────────────────────────────
-- No INSERT / UPDATE / DELETE / CREATE anywhere in PROD
GRANT USAGE ON DATABASE SELFHEALING_PROD
  TO ROLE SELFHEALING_AGENT;

GRANT USAGE ON ALL SCHEMAS IN DATABASE SELFHEALING_PROD
  TO ROLE SELFHEALING_AGENT;

GRANT USAGE ON FUTURE SCHEMAS IN DATABASE SELFHEALING_PROD
  TO ROLE SELFHEALING_AGENT;

GRANT SELECT ON ALL TABLES IN DATABASE SELFHEALING_PROD
  TO ROLE SELFHEALING_AGENT;

GRANT SELECT ON FUTURE TABLES IN DATABASE SELFHEALING_PROD
  TO ROLE SELFHEALING_AGENT;

GRANT SELECT ON ALL VIEWS IN DATABASE SELFHEALING_PROD
  TO ROLE SELFHEALING_AGENT;

GRANT SELECT ON FUTURE VIEWS IN DATABASE SELFHEALING_PROD
  TO ROLE SELFHEALING_AGENT;

-- ── PROD: stored procedure USAGE ─────────────────────────────
-- Procedures not yet created (Steps 2-6); grants applied now
-- and will bind once the procedures exist.
-- NOTE: stored procedure grants require the exact signature.
-- These are applied after procedure creation in the deploy script.

-- ── PROD: narrow write grants ────────────────────────────────
-- Agent may update SCHEMA_CHANGE_EVENTS (pipeline lifecycle only)
-- and ARTIFACT_REGISTRY (artifact_sql after dbt test passes).
-- All other PROD tables remain read-only.
GRANT UPDATE ON TABLE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
  TO ROLE SELFHEALING_AGENT;

GRANT UPDATE ON TABLE SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY
  TO ROLE SELFHEALING_AGENT;

-- ── dbt project: only required on full accounts with PLATFORM_REGISTRY ───────
-- Uncomment if running the full version (not trial):
-- GRANT CREATE DBT PROJECT ON SCHEMA PLATFORM_REGISTRY.DBT
--   TO ROLE SELFHEALING_AGENT;

-- ── Warehouse ─────────────────────────────────────────────────
GRANT USAGE ON WAREHOUSE SELFHEALING_WH
  TO ROLE SELFHEALING_AGENT;

-- ── Cortex AI ─────────────────────────────────────────────────
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER
  TO ROLE SELFHEALING_AGENT;

-- ── Grant role to ACCOUNTADMIN for admin use ──────────────────
GRANT ROLE SELFHEALING_AGENT TO ROLE ACCOUNTADMIN;
