-- ============================================================================
-- postgres_source_setup.sql
-- ----------------------------------------------------------------------------
-- Full-version prerequisite. Run this against the SOURCE PostgreSQL database
-- BEFORE deploying the Openflow CDC connector. It creates the `retail` schema,
-- the three source tables (with primary keys, required for CDC), the grants,
-- and the logical-replication publication the connector subscribes to.
--
-- The table columns intentionally match what the dbt SILVER models expect, so
-- the connector-created BRONZE tables line up with the pipeline (Openflow adds
-- the _SNOWFLAKE_INSERTED_AT / _UPDATED_AT / _DELETED metadata columns itself).
--
-- HOW TO RUN (Snowflake Postgres example):
--   1. Create the instance and save its passwords to ~/.pgpass:
--        CREATE POSTGRES INSTANCE selfhealing_pg
--          COMPUTE_FAMILY = 'STANDARD_M' STORAGE_SIZE_GB = 10
--          AUTHENTICATION_AUTHORITY = POSTGRES;
--   2. Run this file as the `application` user:
--        psql "host=<host> port=5432 dbname=postgres user=application sslmode=require" \
--             -f config/postgres_source_setup.sql
--   3. Grant REPLICATION as the `snowflake_admin` user (see final note) — the
--      `application` user cannot grant itself REPLICATION.
--   4. Load sample data:  python3 load_retail_data.py
--
-- For an external (non-Snowflake) PostgreSQL source, ensure `wal_level=logical`
-- and that the connecting user has REPLICATION + SELECT before running this.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS retail;

-- customers: 12 business columns (matches SILVER.customers)
CREATE TABLE IF NOT EXISTS retail.customers (
    customer_id        VARCHAR(36)  NOT NULL PRIMARY KEY,
    first_name         VARCHAR(100),
    last_name          VARCHAR(100),
    email              VARCHAR(255),
    phone              VARCHAR(50),
    country            VARCHAR(10),
    segment            VARCHAR(50),
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    loyalty_tier       VARCHAR(50),
    preferred_contact  VARCHAR(50),
    preferred_language VARCHAR(50)
);

-- orders (matches SILVER.orders)
CREATE TABLE IF NOT EXISTS retail.orders (
    order_id     VARCHAR(36)   NOT NULL PRIMARY KEY,
    customer_id  VARCHAR(36)   NOT NULL,
    order_date   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    status       VARCHAR(50),
    total_amount NUMERIC(12,2),
    currency     VARCHAR(10),
    channel      VARCHAR(50),
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- order_items (matches SILVER.order_items)
CREATE TABLE IF NOT EXISTS retail.order_items (
    item_id      VARCHAR(36)  NOT NULL PRIMARY KEY,
    order_id     VARCHAR(36)  NOT NULL,
    product_id   VARCHAR(50),
    product_name VARCHAR(255),
    quantity     INTEGER,
    unit_price   NUMERIC(12,2),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

GRANT USAGE ON SCHEMA retail TO application;
GRANT SELECT ON ALL TABLES IN SCHEMA retail TO application;

-- Publication the Openflow CDC connector subscribes to.
-- Use FOR TABLE (not FOR ALL TABLES, which requires superuser).
DROP PUBLICATION IF EXISTS selfhealing_pub;
CREATE PUBLICATION selfhealing_pub
    FOR TABLE retail.customers, retail.orders, retail.order_items;

-- ============================================================================
-- RUN SEPARATELY as `snowflake_admin` (the `application` user cannot do this):
--
--   psql "host=<host> port=5432 dbname=postgres user=snowflake_admin sslmode=require" \
--        -c "ALTER ROLE application REPLICATION;"
--
-- Without the REPLICATION attribute the connector cannot create a replication
-- slot and the snapshot never starts.
-- ============================================================================
