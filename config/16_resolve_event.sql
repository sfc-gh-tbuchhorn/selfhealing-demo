-- =============================================================
-- 16_resolve_event.sql
-- RESOLVE_EVENT(event_id) — advance SCHEMA_REGISTRY to the new
-- baseline for a single event and mark it RESOLVED.
--
-- This is the trial-friendly equivalent of the merge callback.
-- In the full version, a GitHub Action calls SYNC_FROM_MAIN when
-- a PR merges. On trial there is no EAI/Git callback, so after you
-- review and merge the PR you run this manually:
--
--   CALL SELFHEALING_PROD.CONFIG.RESOLVE_EVENT('<event-id>');
--
-- It handles all four change types so the drift detector stops
-- re-flagging the change on the next run.
--
-- EXECUTE AS OWNER: needs DML on the CONFIG registry tables.
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.RESOLVE_EVENT(event_id VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_change_type  VARCHAR;
    v_table_schema VARCHAR;
    v_table_name   VARCHAR;
    v_column_name  VARCHAR;
    v_new_type     VARCHAR;
BEGIN
    SELECT change_type, table_schema, table_name, column_name, new_data_type
      INTO :v_change_type, :v_table_schema, :v_table_name, :v_column_name, :v_new_type
      FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
      WHERE event_id = :event_id;

    IF (v_change_type IS NULL) THEN
        RETURN 'Event not found: ' || :event_id;
    END IF;

    -- NEW_COLUMN — add the column to the baseline
    IF (v_change_type = 'NEW_COLUMN') THEN
        INSERT INTO SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY
            (table_schema, table_name, column_name, data_type)
        SELECT :v_table_schema, :v_table_name, :v_column_name, :v_new_type
        WHERE NOT EXISTS (
            SELECT 1 FROM SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY r
            WHERE r.table_schema = :v_table_schema
              AND r.table_name   = :v_table_name
              AND r.column_name  = :v_column_name
        );

    -- COLUMN_DROP — remove the column from the baseline
    ELSEIF (v_change_type = 'COLUMN_DROP') THEN
        DELETE FROM SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY
        WHERE table_schema = :v_table_schema
          AND table_name   = :v_table_name
          AND column_name  = :v_column_name;

    -- TYPE_CHANGE — update the recorded data type
    ELSEIF (v_change_type = 'TYPE_CHANGE') THEN
        UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY
        SET    data_type = :v_new_type
        WHERE  table_schema = :v_table_schema
          AND  table_name   = :v_table_name
          AND  column_name  = :v_column_name;

    -- NEW_TABLE — baseline all current BRONZE columns of the new table
    ELSEIF (v_change_type = 'NEW_TABLE') THEN
        INSERT INTO SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY
            (table_schema, table_name, column_name, data_type)
        SELECT c.TABLE_SCHEMA, c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
        FROM SELFHEALING_PROD.INFORMATION_SCHEMA.COLUMNS c
        WHERE c.TABLE_SCHEMA = :v_table_schema
          AND c.TABLE_NAME   = :v_table_name
          AND c.COLUMN_NAME NOT LIKE '_SNOWFLAKE_%'
          AND c.COLUMN_NAME NOT LIKE 'PAYLOAD__%'
          AND c.COLUMN_NAME NOT LIKE 'PRIMARY_KEY__%'
          AND NOT EXISTS (
              SELECT 1 FROM SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY r
              WHERE r.table_schema = c.TABLE_SCHEMA
                AND r.table_name   = c.TABLE_NAME
                AND r.column_name  = c.COLUMN_NAME
          );
    END IF;

    -- Mark the event resolved so it is no longer re-detected
    UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
    SET    status          = 'RESOLVED',
           pipeline_status = 'RESOLVED',
           resolved_at     = CURRENT_TIMESTAMP()
    WHERE  event_id = :event_id;

    RETURN 'Resolved ' || v_change_type || ' on ' || v_table_name
        || ' — SCHEMA_REGISTRY advanced, event marked RESOLVED';
END;
$$;
