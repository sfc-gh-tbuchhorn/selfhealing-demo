-- =============================================================
-- 01_config_schema.sql
-- CONFIG schema, 3 registry tables, drift detector task,
-- and impact analysis stored procedure.
--
-- Covers 4 change types:
--   NEW_COLUMN    — Openflow CDC added a column not in registry
--   COLUMN_DROP   — registry has a column no longer in BRONZE
--   TYPE_CHANGE   — column exists in both but data type differs
--   NEW_TABLE     — BRONZE has a table with no registry entries
-- =============================================================

CREATE DATABASE IF NOT EXISTS SELFHEALING_PROD;
CREATE DATABASE IF NOT EXISTS SELFHEALING_DEV;

CREATE WAREHOUSE IF NOT EXISTS SELFHEALING_WH
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE;

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE SCHEMA IF NOT EXISTS SELFHEALING_PROD.CONFIG;

-- -----------------------------------------------------------
-- 1. SCHEMA_REGISTRY
--    Baseline of the last known-good BRONZE schema.
--    Updated only after a GitLab MR is merged + approved.
-- -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY (
    table_schema    VARCHAR        NOT NULL,
    table_name      VARCHAR        NOT NULL,
    column_name     VARCHAR        NOT NULL,
    data_type       VARCHAR        NOT NULL,
    registered_at   TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (table_schema, table_name, column_name)
);

-- -----------------------------------------------------------
-- 2. SCHEMA_CHANGE_EVENTS
--    One row per detected diff.
--    Business lifecycle (status): PENDING → RESOLVED
--    Pipeline lifecycle (pipeline_status):
--      PENDING → GENERATING → GENERATED → TESTING
--      → MR_OPEN → RESOLVED | FAILED
-- -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS (
    event_id            VARCHAR        NOT NULL DEFAULT UUID_STRING(),
    detected_at         TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    table_schema        VARCHAR        NOT NULL,
    table_name          VARCHAR        NOT NULL,
    column_name         VARCHAR,                  -- NULL for NEW_TABLE events
    change_type         VARCHAR        NOT NULL,  -- NEW_COLUMN | COLUMN_DROP | TYPE_CHANGE | NEW_TABLE
    old_data_type       VARCHAR,                  -- populated for TYPE_CHANGE and COLUMN_DROP
    new_data_type       VARCHAR,                  -- populated for NEW_COLUMN and TYPE_CHANGE
    status              VARCHAR        NOT NULL DEFAULT 'PENDING',
    pipeline_status     VARCHAR        NOT NULL DEFAULT 'PENDING',
    branch_name         VARCHAR,                  -- git branch, set after dbt PASS
    mr_url              VARCHAR,                  -- GitHub PR link, set after push
    generated_changes   VARIANT,                  -- [{artifact_name, file_path, action, original_sql, generated_sql}]
    test_output         VARCHAR,                  -- dbt stdout, set after test run
    resolved_at         TIMESTAMP_NTZ,
    PRIMARY KEY (event_id)
);

-- -----------------------------------------------------------
-- 3. ARTIFACT_REGISTRY
--    Maps each source table → downstream dbt models / COPY INTOs.
--    source_columns = NULL means depends on all columns in source_table
--    (any change triggers re-generation of that artifact).
-- -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY (
    artifact_id     VARCHAR        NOT NULL DEFAULT UUID_STRING(),
    artifact_name   VARCHAR        NOT NULL,  -- e.g. 'silver.customers'
    artifact_type   VARCHAR        NOT NULL,  -- 'dbt_model' | 'copy_into'
    source_table    VARCHAR        NOT NULL,  -- e.g. 'BRONZE.CUSTOMERS'
    source_columns  ARRAY,                    -- NULL = whole-table dependency
    artifact_sql    VARCHAR        NOT NULL,  -- current SQL (kept in sync by agent)
    file_path       VARCHAR        NOT NULL,  -- repo path, e.g. models/silver/customers.sql
    snowflake_fqn   VARCHAR,                  -- output table FQN, e.g. SELFHEALING_PROD.SILVER.ORDERS
    updated_at      TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (artifact_id)
);

-- Pipeline configuration (populated during setup via env vars)
CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.CONFIG.SETTINGS (
    key   VARCHAR NOT NULL PRIMARY KEY,
    value VARCHAR NOT NULL
);

-- Prompt staging — passes prompts to CORTEX.COMPLETE from inside
-- nested stored procs (avoids the temp-view restriction).
CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.CONFIG.PROMPT_STAGING (
    job_id  VARCHAR NOT NULL,
    prompt  VARCHAR NOT NULL
);

-- Generated code — full regenerated SQL per artifact, written by
-- GENERATE_ARTIFACT_CODE and consumed by materialise_in_dev.py.
CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.CONFIG.GENERATED_CODE (
    event_id       VARCHAR        NOT NULL,
    artifact_name  VARCHAR        NOT NULL,
    file_path      VARCHAR        NOT NULL,
    action         VARCHAR        NOT NULL,
    generated_sql  VARCHAR        NOT NULL,
    test_status    VARCHAR,
    test_error     VARCHAR,
    generated_at   TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
);
