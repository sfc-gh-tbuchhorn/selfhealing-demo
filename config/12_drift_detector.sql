-- =============================================================
-- 03_drift_detector.sql
-- Schema drift detection task covering all 4 change types.
-- Runs every 15 minutes. Only inserts NEW events (deduped
-- against existing PENDING/IN_PROGRESS rows so re-runs
-- don't create duplicate events for the same change).
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.SCHEMA_DRIFT_DETECTOR
  WAREHOUSE = SELFHEALING_WH
  SCHEDULE  = '15 MINUTE'
AS
INSERT INTO SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
    (table_schema, table_name, column_name, change_type, old_data_type, new_data_type)

-- ── 1. NEW_COLUMN ─────────────────────────────────────────
-- BRONZE has a column the registry doesn't know about.
-- Openflow CDC silently adds columns when source schema changes.
SELECT
    c.TABLE_SCHEMA,
    c.TABLE_NAME,
    c.COLUMN_NAME,
    'NEW_COLUMN'        AS change_type,
    NULL                AS old_data_type,
    c.DATA_TYPE         AS new_data_type
FROM SELFHEALING_PROD.INFORMATION_SCHEMA.COLUMNS c
LEFT JOIN SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY r
       ON c.TABLE_SCHEMA = r.table_schema
      AND c.TABLE_NAME   = r.table_name
      AND c.COLUMN_NAME  = r.column_name
WHERE c.TABLE_SCHEMA = 'BRONZE'
  -- exclude Openflow CDC journal tables
  AND c.TABLE_NAME NOT LIKE '%\_JOURNAL\_%'
  -- exclude Openflow CDC internal columns
  AND c.COLUMN_NAME NOT LIKE '_SNOWFLAKE_%'
  AND c.COLUMN_NAME NOT LIKE 'PAYLOAD__%'
  AND c.COLUMN_NAME NOT LIKE 'PRIMARY_KEY__%'
  AND c.COLUMN_NAME NOT LIKE '%\_\_SNOWFLAKE\_DELETED'
  AND c.COLUMN_NAME NOT IN (
      'LEAST_SIGNIFICANT_POSITION','MOST_SIGNIFICANT_POSITION',
      'EVENT_TYPE','SEEN_AT','SF_METADATA'
  )
  AND r.column_name IS NULL
  -- dedupe: skip if we already have a live event for this column
  AND NOT EXISTS (
      SELECT 1 FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS e
      WHERE e.table_schema = c.TABLE_SCHEMA
        AND e.table_name   = c.TABLE_NAME
        AND e.column_name  = c.COLUMN_NAME
        AND e.change_type  = 'NEW_COLUMN'
        AND e.status IN ('PENDING','IN_PROGRESS')
  )

UNION ALL

-- ── 2. COLUMN_DROP ────────────────────────────────────────
-- Openflow renames dropped columns to <col>__SNOWFLAKE_DELETED
-- (documented connector behaviour — no column is ever physically
-- dropped from BRONZE). We detect the rename via INFORMATION_SCHEMA
-- and join back to SCHEMA_REGISTRY on the original column name.
-- Ref: docs.snowflake.com/en/user-guide/data-integration/openflow/
--      connectors/mysql/about#dropped-columns
SELECT
    c.TABLE_SCHEMA,
    c.TABLE_NAME,
    REPLACE(c.COLUMN_NAME, '__SNOWFLAKE_DELETED', '') AS column_name,
    'COLUMN_DROP'       AS change_type,
    r.data_type         AS old_data_type,
    NULL                AS new_data_type
FROM SELFHEALING_PROD.INFORMATION_SCHEMA.COLUMNS c
JOIN SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY r
  ON  r.table_schema = c.TABLE_SCHEMA
  AND r.table_name   = c.TABLE_NAME
  AND r.column_name  = REPLACE(c.COLUMN_NAME, '__SNOWFLAKE_DELETED', '')
WHERE c.TABLE_SCHEMA = 'BRONZE'
  AND c.COLUMN_NAME  LIKE '%\_\_SNOWFLAKE\_DELETED'
  AND NOT EXISTS (
      SELECT 1 FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS e
      WHERE e.table_schema = c.TABLE_SCHEMA
        AND e.table_name   = c.TABLE_NAME
        AND e.column_name  = REPLACE(c.COLUMN_NAME, '__SNOWFLAKE_DELETED', '')
        AND e.change_type  = 'COLUMN_DROP'
        AND e.status IN ('PENDING','IN_PROGRESS')
  )

UNION ALL

-- ── 3. TYPE_CHANGE ────────────────────────────────────────
-- Column exists in both but Openflow re-mapped the type
-- (e.g. source VARCHAR widened, Postgres NUMERIC → FLOAT).
SELECT
    c.TABLE_SCHEMA,
    c.TABLE_NAME,
    c.COLUMN_NAME,
    'TYPE_CHANGE'       AS change_type,
    r.data_type         AS old_data_type,
    c.DATA_TYPE         AS new_data_type
FROM SELFHEALING_PROD.INFORMATION_SCHEMA.COLUMNS c
JOIN SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY r
  ON c.TABLE_SCHEMA = r.table_schema
 AND c.TABLE_NAME   = r.table_name
 AND c.COLUMN_NAME  = r.column_name
WHERE c.TABLE_SCHEMA = 'BRONZE'
  AND c.DATA_TYPE   != r.data_type
  AND NOT EXISTS (
      SELECT 1 FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS e
      WHERE e.table_schema = c.TABLE_SCHEMA
        AND e.table_name   = c.TABLE_NAME
        AND e.column_name  = c.COLUMN_NAME
        AND e.change_type  = 'TYPE_CHANGE'
        AND e.status IN ('PENDING','IN_PROGRESS')
  )

UNION ALL

-- ── 4. NEW_TABLE ──────────────────────────────────────────
-- A table exists in BRONZE with no registry entries at all.
-- Openflow CDC creates new tables automatically when a new
-- source table is added to the publication.
SELECT
    c.TABLE_SCHEMA,
    c.TABLE_NAME,
    NULL                AS column_name,
    'NEW_TABLE'         AS change_type,
    NULL                AS old_data_type,
    NULL                AS new_data_type
FROM SELFHEALING_PROD.INFORMATION_SCHEMA.TABLES c
WHERE c.TABLE_SCHEMA = 'BRONZE'
  AND c.TABLE_TYPE   = 'BASE TABLE'
  AND c.TABLE_NAME NOT LIKE '%\_JOURNAL\_%'
  AND NOT EXISTS (
      SELECT 1 FROM SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY r
      WHERE r.table_schema = c.TABLE_SCHEMA
        AND r.table_name   = c.TABLE_NAME
  )
  AND NOT EXISTS (
      SELECT 1 FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS e
      WHERE e.table_schema = c.TABLE_SCHEMA
        AND e.table_name   = c.TABLE_NAME
        AND e.change_type  = 'NEW_TABLE'
        AND e.status IN ('PENDING','IN_PROGRESS')
  );

ALTER TASK SELFHEALING_PROD.CONFIG.SCHEMA_DRIFT_DETECTOR RESUME;
