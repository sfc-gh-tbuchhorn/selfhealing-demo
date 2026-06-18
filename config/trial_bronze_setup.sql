-- =============================================================
-- trial_bronze_setup.sql
-- Trial account only — creates BRONZE schema and tables
-- matching the exact schema Openflow CDC would produce,
-- including Openflow metadata columns.
--
-- Run AFTER 01_config_schema.sql (database + warehouse must exist).
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE SCHEMA IF NOT EXISTS SELFHEALING_PROD.BRONZE;

-- ── Tables (Openflow CDC schema) ──────────────────────────────

CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.BRONZE.CUSTOMERS (
    CUSTOMER_ID          INT,
    FIRST_NAME           VARCHAR,
    LAST_NAME            VARCHAR,
    EMAIL                VARCHAR,
    PHONE                VARCHAR,
    COUNTRY              VARCHAR,
    SEGMENT              VARCHAR,
    CREATED_AT           TIMESTAMP,
    UPDATED_AT           TIMESTAMP,
    LOYALTY_TIER         VARCHAR,
    PREFERRED_CONTACT    VARCHAR,
    PREFERRED_LANGUAGE   VARCHAR,
    _SNOWFLAKE_INSERTED_AT  TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    _SNOWFLAKE_UPDATED_AT   TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    _SNOWFLAKE_DELETED      BOOLEAN   DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.BRONZE.ORDERS (
    ORDER_ID        INT,
    CUSTOMER_ID     INT,
    ORDER_DATE      DATE,
    STATUS          VARCHAR,
    TOTAL_AMOUNT    FLOAT,
    CURRENCY        VARCHAR,
    CHANNEL         VARCHAR,
    CREATED_AT      TIMESTAMP,
    UPDATED_AT      TIMESTAMP,
    _SNOWFLAKE_INSERTED_AT  TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    _SNOWFLAKE_UPDATED_AT   TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    _SNOWFLAKE_DELETED      BOOLEAN   DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.BRONZE.ORDER_ITEMS (
    ITEM_ID         INT,
    ORDER_ID        INT,
    PRODUCT_ID      INT,
    PRODUCT_NAME    VARCHAR,
    QUANTITY        INT,
    UNIT_PRICE      FLOAT,
    CREATED_AT      TIMESTAMP,
    _SNOWFLAKE_INSERTED_AT  TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    _SNOWFLAKE_UPDATED_AT   TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    _SNOWFLAKE_DELETED      BOOLEAN   DEFAULT FALSE
);

-- ── Sample data ───────────────────────────────────────────────

INSERT INTO SELFHEALING_PROD.BRONZE.CUSTOMERS
    (CUSTOMER_ID, FIRST_NAME, LAST_NAME, EMAIL, PHONE, COUNTRY, SEGMENT, CREATED_AT, UPDATED_AT, LOYALTY_TIER, PREFERRED_CONTACT, PREFERRED_LANGUAGE)
VALUES
    (1,  'Alice',  'Johnson', 'alice@example.com',  '+61400000001', 'Australia',   'Enterprise', '2024-01-01', '2024-01-01', 'Gold',   'email',  'en'),
    (2,  'Bob',    'Smith',   'bob@example.com',    '+61400000002', 'Australia',   'SMB',        '2024-01-01', '2024-01-01', 'Silver', 'phone',  'en'),
    (3,  'Carol',  'White',   'carol@example.com',  '+64400000003', 'New Zealand', 'Enterprise', '2024-01-01', '2024-01-01', 'Gold',   'email',  'en'),
    (4,  'David',  'Brown',   'david@example.com',  '+65400000004', 'Singapore',   'SMB',        '2024-01-01', '2024-01-01', 'Bronze', 'email',  'en'),
    (5,  'Emma',   'Davis',   'emma@example.com',   '+61400000005', 'Australia',   'Consumer',   '2024-01-01', '2024-01-01', 'Silver', 'mobile', 'en'),
    (6,  'Frank',  'Miller',  'frank@example.com',  '+91400000006', 'India',       'SMB',        '2024-01-01', '2024-01-01', 'Bronze', 'phone',  'en'),
    (7,  'Grace',  'Wilson',  'grace@example.com',  '+61400000007', 'Australia',   'Enterprise', '2024-01-01', '2024-01-01', 'Gold',   'email',  'en'),
    (8,  'Henry',  'Moore',   'henry@example.com',  '+64400000008', 'New Zealand', 'Consumer',   '2024-01-01', '2024-01-01', 'Bronze', 'mobile', 'en'),
    (9,  'Isla',   'Taylor',  'isla@example.com',   '+65400000009', 'Singapore',   'Enterprise', '2024-01-01', '2024-01-01', 'Gold',   'email',  'en'),
    (10, 'Jack',   'Anderson','jack@example.com',   '+61400000010', 'Australia',   'SMB',        '2024-01-01', '2024-01-01', 'Silver', 'phone',  'en');

INSERT INTO SELFHEALING_PROD.BRONZE.ORDERS
    (ORDER_ID, CUSTOMER_ID, ORDER_DATE, STATUS, TOTAL_AMOUNT, CURRENCY, CHANNEL, CREATED_AT, UPDATED_AT)
VALUES
    (1,  1,  '2024-01-05', 'completed',  250.00,  'AUD', 'web',    '2024-01-05', '2024-01-05'),
    (2,  2,  '2024-01-07', 'completed',  89.99,   'AUD', 'mobile', '2024-01-07', '2024-01-07'),
    (3,  1,  '2024-01-10', 'shipped',    430.50,  'AUD', 'web',    '2024-01-10', '2024-01-10'),
    (4,  3,  '2024-01-12', 'completed',  120.00,  'NZD', 'web',    '2024-01-12', '2024-01-12'),
    (5,  4,  '2024-01-14', 'cancelled',  55.00,   'SGD', 'mobile', '2024-01-14', '2024-01-14'),
    (6,  5,  '2024-01-15', 'completed',  310.75,  'AUD', 'web',    '2024-01-15', '2024-01-15'),
    (7,  6,  '2024-01-18', 'completed',  99.00,   'INR', 'mobile', '2024-01-18', '2024-01-18'),
    (8,  7,  '2024-01-20', 'shipped',    640.00,  'AUD', 'web',    '2024-01-20', '2024-01-20'),
    (9,  8,  '2024-01-22', 'completed',  175.25,  'NZD', 'web',    '2024-01-22', '2024-01-22'),
    (10, 9,  '2024-01-23', 'completed',  520.00,  'SGD', 'mobile', '2024-01-23', '2024-01-23'),
    (11, 10, '2024-01-25', 'shipped',    88.50,   'AUD', 'web',    '2024-01-25', '2024-01-25'),
    (12, 1,  '2024-01-27', 'completed',  199.99,  'AUD', 'web',    '2024-01-27', '2024-01-27'),
    (13, 2,  '2024-01-28', 'completed',  45.00,   'AUD', 'mobile', '2024-01-28', '2024-01-28'),
    (14, 3,  '2024-01-29', 'cancelled',  300.00,  'NZD', 'web',    '2024-01-29', '2024-01-29'),
    (15, 5,  '2024-01-30', 'completed',  215.00,  'AUD', 'web',    '2024-01-30', '2024-01-30');

INSERT INTO SELFHEALING_PROD.BRONZE.ORDER_ITEMS
    (ITEM_ID, ORDER_ID, PRODUCT_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, CREATED_AT)
VALUES
    (1,  1,  101, 'Laptop Stand',        1, 50.00,  '2024-01-05'),
    (2,  1,  102, 'Wireless Mouse',      2, 35.00,  '2024-01-05'),
    (3,  1,  103, 'USB Hub',             1, 130.00, '2024-01-05'),
    (4,  2,  104, 'Keyboard',            1, 89.99,  '2024-01-07'),
    (5,  3,  105, 'Monitor',             1, 380.00, '2024-01-10'),
    (6,  3,  106, 'HDMI Cable',          2, 25.25,  '2024-01-10'),
    (7,  4,  107, 'Webcam',              1, 120.00, '2024-01-12'),
    (8,  5,  108, 'Mouse Pad',           1, 55.00,  '2024-01-14'),
    (9,  6,  109, 'Headphones',          1, 199.00, '2024-01-15'),
    (10, 6,  110, 'Phone Stand',         2, 55.875, '2024-01-15'),
    (11, 7,  111, 'USB-C Cable',         3, 33.00,  '2024-01-18'),
    (12, 8,  112, 'Mechanical Keyboard', 1, 280.00, '2024-01-20'),
    (13, 8,  113, 'Desk Mat',            1, 360.00, '2024-01-20'),
    (14, 9,  114, 'Laptop Bag',          1, 175.25, '2024-01-22'),
    (15, 10, 115, 'External SSD',        1, 520.00, '2024-01-23'),
    (16, 11, 116, 'Screen Cleaner',      2, 44.25,  '2024-01-25'),
    (17, 12, 107, 'Webcam',              1, 199.99, '2024-01-27'),
    (18, 13, 108, 'Mouse Pad',           1, 45.00,  '2024-01-28'),
    (19, 14, 117, 'Monitor Arm',         1, 300.00, '2024-01-29'),
    (20, 15, 118, 'Cable Management',    1, 215.00, '2024-01-30');
