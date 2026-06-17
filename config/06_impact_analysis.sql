-- =============================================================
-- 04_impact_analysis.sql
-- GET_IMPACTED_ARTIFACTS — SQL stored procedure
--
-- Two branches:
--
-- Column changes (NEW_COLUMN, COLUMN_DROP, TYPE_CHANGE):
--   → Recursive CTE on ARTIFACT_REGISTRY (source_table → snowflake_fqn)
--   → Returns full transitive dependency graph with impact path
--   → Registry is refreshed at dbt deploy time via
--     refresh_artifact_registry.py — no runtime dbt execution needed
--
-- New table (NEW_TABLE):
--   → Reads BRONZE columns from INFORMATION_SCHEMA
--   → Returns a 'generate' block the agent passes to AI_COMPLETE
--     to create the sources.yml entry + new SILVER model
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.GET_IMPACTED_ARTIFACTS(
    event_id VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_table_name  VARCHAR;
    v_column_name VARCHAR;
    v_change_type VARCHAR;
    v_old_type    VARCHAR;
    v_new_type    VARCHAR;
    v_is_breaking BOOLEAN;
    result        VARIANT;
BEGIN
    -- ── Fetch event ───────────────────────────────────────────
    SELECT TABLE_NAME, COLUMN_NAME, CHANGE_TYPE, OLD_DATA_TYPE, NEW_DATA_TYPE
    INTO   :v_table_name, :v_column_name, :v_change_type, :v_old_type, :v_new_type
    FROM   SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
    WHERE  EVENT_ID = :event_id;

    v_is_breaking := (v_change_type IN ('COLUMN_DROP', 'TYPE_CHANGE'));

    -- ── Branch 1: column-level changes ───────────────────────
    IF (v_change_type IN ('NEW_COLUMN', 'COLUMN_DROP', 'TYPE_CHANGE')) THEN

        LET result VARIANT := (
            WITH RECURSIVE impact AS (

                -- Seed: direct dependents of the changed BRONZE table
                SELECT
                    a.artifact_name,
                    a.artifact_type,
                    a.file_path,
                    a.snowflake_fqn,
                    a.source_table,
                    1                                                AS depth,
                    'BRONZE.' || :v_table_name || ' → ' || a.snowflake_fqn
                                                                     AS impact_path
                FROM SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY a
                WHERE a.source_table = 'BRONZE.' || :v_table_name

                UNION ALL

                -- Recurse: dependents of dependents
                SELECT
                    a.artifact_name,
                    a.artifact_type,
                    a.file_path,
                    a.snowflake_fqn,
                    a.source_table,
                    i.depth + 1,
                    i.impact_path || ' → ' || a.snowflake_fqn
                FROM SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY a
                JOIN impact i
                  ON a.source_table = REPLACE(i.snowflake_fqn, 'SELFHEALING_PROD.', '')
            )
            SELECT OBJECT_CONSTRUCT(
                'event', OBJECT_CONSTRUCT(
                    'event_id',    :event_id,
                    'table_name',  :v_table_name,
                    'column_name', NVL(:v_column_name, ''),
                    'change_type', :v_change_type,
                    'old_type',    NVL(:v_old_type, ''),
                    'new_type',    NVL(:v_new_type, ''),
                    'is_breaking', :v_is_breaking
                ),
                'impacted', (
                    SELECT ARRAY_AGG(
                        OBJECT_CONSTRUCT(
                            'artifact_name', artifact_name,
                            'artifact_type', artifact_type,
                            'file_path',     file_path,
                            'snowflake_fqn', snowflake_fqn,
                            'depth',         depth,
                            'impact_path',   impact_path
                        )
                    )
                    FROM (SELECT DISTINCT artifact_name, artifact_type,
                                          file_path, snowflake_fqn,
                                          MIN(depth)       AS depth,
                                          MIN(impact_path) AS impact_path
                          FROM impact
                          GROUP BY 1,2,3,4) AS deduped
                    ORDER BY deduped.depth ASC, deduped.artifact_name ASC
                )
            )
            FROM (SELECT 1)
        );
        RETURN result;

    -- ── Branch 2: new table — generate new model ─────────────
    ELSEIF (v_change_type = 'NEW_TABLE') THEN

        LET result VARIANT := (
            SELECT OBJECT_CONSTRUCT(
                'event', OBJECT_CONSTRUCT(
                    'event_id',    :event_id,
                    'table_name',  :v_table_name,
                    'column_name', '',
                    'change_type', 'NEW_TABLE',
                    'is_breaking', FALSE
                ),
                'impacted', ARRAY_CONSTRUCT(),
                'generate', OBJECT_CONSTRUCT(
                    'action',            'CREATE',
                    'silver_model_path', 'models/silver/' || LOWER(:v_table_name) || '.sql',
                    'sources_yml_path',  'models/sources.yml',
                    'primary_key', (
                        SELECT COLUMN_NAME
                        FROM   SELFHEALING_PROD.INFORMATION_SCHEMA.COLUMNS
                        WHERE  TABLE_SCHEMA = 'BRONZE'
                          AND  TABLE_NAME   = :v_table_name
                          AND  COLUMN_NAME  ILIKE '%\\_id' ESCAPE '\\'
                          AND  COLUMN_NAME NOT LIKE '_SNOWFLAKE_%'
                        ORDER BY ORDINAL_POSITION
                        LIMIT 1
                    ),
                    'columns', (
                        SELECT ARRAY_AGG(
                            OBJECT_CONSTRUCT('name', COLUMN_NAME, 'type', DATA_TYPE)
                        )
                        FROM (
                            SELECT COLUMN_NAME, DATA_TYPE
                            FROM SELFHEALING_PROD.INFORMATION_SCHEMA.COLUMNS
                            WHERE TABLE_SCHEMA = 'BRONZE'
                              AND TABLE_NAME   = :v_table_name
                              AND COLUMN_NAME NOT LIKE '_SNOWFLAKE_%'
                              AND COLUMN_NAME NOT LIKE 'PAYLOAD\\_\\_%'
                              AND COLUMN_NAME NOT LIKE 'PRIMARY\\_KEY\\_\\_%'
                              AND COLUMN_NAME NOT IN (
                                  'LEAST_SIGNIFICANT_POSITION','MOST_SIGNIFICANT_POSITION',
                                  'EVENT_TYPE','SEEN_AT','SF_METADATA'
                              )
                            ORDER BY ORDINAL_POSITION
                        )
                    )
                )
            )
            FROM (SELECT 1)
        );
        RETURN result;

    END IF;

    RETURN OBJECT_CONSTRUCT('error', 'Unknown change_type: ' || :v_change_type);
END;
$$;

-- ── Helper view — unchanged ───────────────────────────────────
CREATE OR REPLACE VIEW SELFHEALING_PROD.CONFIG.PENDING_SCHEMA_CHANGES AS
SELECT
    EVENT_ID,
    DETECTED_AT,
    TABLE_SCHEMA,
    TABLE_NAME,
    COLUMN_NAME,
    CHANGE_TYPE,
    OLD_DATA_TYPE,
    NEW_DATA_TYPE,
    CASE CHANGE_TYPE
        WHEN 'COLUMN_DROP' THEN 'HIGH'
        WHEN 'TYPE_CHANGE' THEN 'HIGH'
        WHEN 'NEW_COLUMN'  THEN 'MEDIUM'
        WHEN 'NEW_TABLE'   THEN 'LOW'
    END AS priority
FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
WHERE STATUS = 'PENDING'
ORDER BY
    CASE CHANGE_TYPE
        WHEN 'COLUMN_DROP' THEN 1
        WHEN 'TYPE_CHANGE' THEN 2
        WHEN 'NEW_COLUMN'  THEN 3
        WHEN 'NEW_TABLE'   THEN 4
    END,
    DETECTED_AT;
