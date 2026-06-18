-- =============================================================
-- 11_seed_registry.sql
-- Seed SCHEMA_REGISTRY from the current BRONZE schema (the drift
-- detector's known-good baseline). Run once after BRONZE exists.
--
-- ARTIFACT_REGISTRY is normally owned by the dbt on-run-end hook
-- (macros/refresh_artifact_registry.sql), which rewrites it from
-- the real dbt graph on every PROD dbt run. The seed below is an
-- idempotent FALLBACK: it only inserts when ARTIFACT_REGISTRY has
-- no dbt_model rows yet, so it never duplicates rows the hook has
-- already written (trial runs an initial PROD dbt run first), and
-- it still provides an initial graph on accounts where no PROD
-- dbt run has happened yet (full version).
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

-- -----------------------------------------------------------
-- Seed SCHEMA_REGISTRY
-- Exclude Openflow CDC metadata columns (_SNOWFLAKE_*)
-- and internal journal columns (PRIMARY_KEY__, PAYLOAD__,
-- LEAST_SIGNIFICANT_POSITION, MOST_SIGNIFICANT_POSITION,
-- EVENT_TYPE, SEEN_AT, SF_METADATA) — these are connector
-- internals, not source schema columns.
-- -----------------------------------------------------------
INSERT INTO SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY
    (table_schema, table_name, column_name, data_type)
SELECT
    c.TABLE_SCHEMA,
    c.TABLE_NAME,
    c.COLUMN_NAME,
    c.DATA_TYPE
FROM SELFHEALING_PROD.INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_SCHEMA = 'BRONZE'
  AND c.COLUMN_NAME NOT LIKE '_SNOWFLAKE_%'
  AND c.COLUMN_NAME NOT LIKE 'PAYLOAD__%'
  AND c.COLUMN_NAME NOT LIKE 'PRIMARY_KEY__%'
  AND c.COLUMN_NAME NOT IN (
      'LEAST_SIGNIFICANT_POSITION',
      'MOST_SIGNIFICANT_POSITION',
      'EVENT_TYPE',
      'SEEN_AT',
      'SF_METADATA'
  )
  AND NOT EXISTS (
      SELECT 1 FROM SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY r
      WHERE r.table_schema = c.TABLE_SCHEMA
        AND r.table_name   = c.TABLE_NAME
        AND r.column_name  = c.COLUMN_NAME
  );

-- Verify baseline
SELECT TABLE_NAME, COUNT(*) AS col_count
FROM   SELFHEALING_PROD.CONFIG.SCHEMA_REGISTRY
GROUP BY 1
ORDER BY 1;

-- -----------------------------------------------------------
-- Seed ARTIFACT_REGISTRY (idempotent fallback — only if empty)
-- One row per source_table dependency. GOLD models that join
-- SILVER tables get separate rows so either upstream change
-- triggers re-generation.
-- -----------------------------------------------------------
INSERT INTO SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY
    (artifact_name, artifact_type, source_table, source_columns, artifact_sql, file_path, snowflake_fqn)
SELECT artifact_name, artifact_type, source_table, source_columns, artifact_sql, file_path, snowflake_fqn
FROM (
    SELECT 'silver.customers' AS artifact_name, 'dbt_model' AS artifact_type, 'BRONZE.CUSTOMERS' AS source_table, NULL AS source_columns,
           'SELECT CUSTOMER_ID, FIRST_NAME, LAST_NAME, EMAIL, PHONE, COUNTRY, SEGMENT, CREATED_AT, UPDATED_AT, _SNOWFLAKE_INSERTED_AT, _SNOWFLAKE_UPDATED_AT FROM SELFHEALING_PROD.BRONZE.CUSTOMERS WHERE (_SNOWFLAKE_DELETED IS NULL OR _SNOWFLAKE_DELETED = FALSE) QUALIFY ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY _SNOWFLAKE_UPDATED_AT DESC) = 1' AS artifact_sql,
           'models/silver/customers.sql' AS file_path, 'SELFHEALING_PROD.SILVER.CUSTOMERS' AS snowflake_fqn
    UNION ALL
    SELECT 'silver.orders', 'dbt_model', 'BRONZE.ORDERS', NULL,
           'SELECT ORDER_ID, CUSTOMER_ID, ORDER_DATE, STATUS, TOTAL_AMOUNT, CURRENCY, CHANNEL, CREATED_AT, UPDATED_AT, _SNOWFLAKE_INSERTED_AT, _SNOWFLAKE_UPDATED_AT FROM SELFHEALING_PROD.BRONZE.ORDERS WHERE (_SNOWFLAKE_DELETED IS NULL OR _SNOWFLAKE_DELETED = FALSE) QUALIFY ROW_NUMBER() OVER (PARTITION BY ORDER_ID ORDER BY _SNOWFLAKE_UPDATED_AT DESC) = 1',
           'models/silver/orders.sql', 'SELFHEALING_PROD.SILVER.ORDERS'
    UNION ALL
    SELECT 'silver.order_items', 'dbt_model', 'BRONZE.ORDER_ITEMS', NULL,
           'SELECT ITEM_ID, ORDER_ID, PRODUCT_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, CREATED_AT, _SNOWFLAKE_INSERTED_AT, _SNOWFLAKE_UPDATED_AT FROM SELFHEALING_PROD.BRONZE.ORDER_ITEMS WHERE (_SNOWFLAKE_DELETED IS NULL OR _SNOWFLAKE_DELETED = FALSE) QUALIFY ROW_NUMBER() OVER (PARTITION BY ITEM_ID ORDER BY _SNOWFLAKE_UPDATED_AT DESC) = 1',
           'models/silver/order_items.sql', 'SELFHEALING_PROD.SILVER.ORDER_ITEMS'
    UNION ALL
    SELECT 'gold.orders_daily', 'dbt_model', 'SILVER.ORDERS', NULL,
           'SELECT DATE_TRUNC(''DAY'', o.ORDER_DATE) AS order_date, c.COUNTRY, c.SEGMENT, o.CHANNEL, o.STATUS, COUNT(DISTINCT o.ORDER_ID) AS order_count, COUNT(DISTINCT o.CUSTOMER_ID) AS customer_count, SUM(o.TOTAL_AMOUNT) AS total_revenue, AVG(o.TOTAL_AMOUNT) AS avg_order_value FROM SELFHEALING_PROD.SILVER.ORDERS o JOIN SELFHEALING_PROD.SILVER.CUSTOMERS c ON o.CUSTOMER_ID = c.CUSTOMER_ID GROUP BY 1,2,3,4,5',
           'models/gold/orders_daily.sql', 'SELFHEALING_PROD.GOLD.ORDERS_DAILY'
    UNION ALL
    SELECT 'gold.orders_daily', 'dbt_model', 'SILVER.CUSTOMERS', NULL,
           'SELECT DATE_TRUNC(''DAY'', o.ORDER_DATE) AS order_date, c.COUNTRY, c.SEGMENT, o.CHANNEL, o.STATUS, COUNT(DISTINCT o.ORDER_ID) AS order_count, COUNT(DISTINCT o.CUSTOMER_ID) AS customer_count, SUM(o.TOTAL_AMOUNT) AS total_revenue, AVG(o.TOTAL_AMOUNT) AS avg_order_value FROM SELFHEALING_PROD.SILVER.ORDERS o JOIN SELFHEALING_PROD.SILVER.CUSTOMERS c ON o.CUSTOMER_ID = c.CUSTOMER_ID GROUP BY 1,2,3,4,5',
           'models/gold/orders_daily.sql', 'SELFHEALING_PROD.GOLD.ORDERS_DAILY'
    UNION ALL
    SELECT 'gold.category_summary', 'dbt_model', 'SILVER.ORDER_ITEMS', NULL,
           'SELECT oi.CATEGORY, COUNT(DISTINCT oi.ITEM_ID) AS items_sold, SUM(oi.QUANTITY) AS total_units, SUM(oi.QUANTITY * oi.UNIT_PRICE) AS total_revenue, AVG(oi.UNIT_PRICE) AS avg_unit_price, COUNT(DISTINCT oi.ORDER_ID) AS order_count FROM SELFHEALING_PROD.SILVER.ORDER_ITEMS oi GROUP BY 1',
           'models/gold/category_summary.sql', 'SELFHEALING_PROD.GOLD.CATEGORY_SUMMARY'
) src
WHERE NOT EXISTS (
    SELECT 1 FROM SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY
    WHERE artifact_type = 'dbt_model'
);

-- Verify
SELECT ARTIFACT_NAME, ARTIFACT_TYPE, SOURCE_TABLE
FROM   SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY
ORDER BY SOURCE_TABLE, ARTIFACT_NAME;
