-- =============================================================
-- 00_trial_setup.sql
-- Trial account only — creates BRONZE schema and tables with
-- sample data, simulating what Openflow CDC would produce.
--
-- Run this INSTEAD of configuring Openflow.
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE SCHEMA IF NOT EXISTS SELFHEALING_PROD.BRONZE;

-- ── Tables ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.BRONZE.CUSTOMERS (
    id          INT,
    name        VARCHAR,
    email       VARCHAR,
    country     VARCHAR,
    segment     VARCHAR,
    _loaded_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.BRONZE.ORDERS (
    id              INT,
    customer_id     INT,
    status          VARCHAR,
    total_amount    FLOAT,
    order_date      DATE,
    channel         VARCHAR,
    _loaded_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS SELFHEALING_PROD.BRONZE.ORDER_ITEMS (
    id          INT,
    order_id    INT,
    product     VARCHAR,
    quantity    INT,
    unit_price  FLOAT,
    _loaded_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- ── Sample data ───────────────────────────────────────────────

INSERT INTO SELFHEALING_PROD.BRONZE.CUSTOMERS (id, name, email, country, segment) VALUES
    (1,  'Alice Johnson',  'alice@example.com',   'Australia',    'Enterprise'),
    (2,  'Bob Smith',      'bob@example.com',     'Australia',    'SMB'),
    (3,  'Carol White',    'carol@example.com',   'New Zealand',  'Enterprise'),
    (4,  'David Brown',    'david@example.com',   'Singapore',    'SMB'),
    (5,  'Emma Davis',     'emma@example.com',    'Australia',    'Consumer'),
    (6,  'Frank Miller',   'frank@example.com',   'India',        'SMB'),
    (7,  'Grace Wilson',   'grace@example.com',   'Australia',    'Enterprise'),
    (8,  'Henry Moore',    'henry@example.com',   'New Zealand',  'Consumer'),
    (9,  'Isla Taylor',    'isla@example.com',    'Singapore',    'Enterprise'),
    (10, 'Jack Anderson',  'jack@example.com',    'Australia',    'SMB');

INSERT INTO SELFHEALING_PROD.BRONZE.ORDERS (id, customer_id, status, total_amount, order_date, channel) VALUES
    (1,  1,  'completed',  250.00,  '2024-01-05', 'web'),
    (2,  2,  'completed',  89.99,   '2024-01-07', 'mobile'),
    (3,  1,  'shipped',    430.50,  '2024-01-10', 'web'),
    (4,  3,  'completed',  120.00,  '2024-01-12', 'web'),
    (5,  4,  'cancelled',  55.00,   '2024-01-14', 'mobile'),
    (6,  5,  'completed',  310.75,  '2024-01-15', 'web'),
    (7,  6,  'completed',  99.00,   '2024-01-18', 'mobile'),
    (8,  7,  'shipped',    640.00,  '2024-01-20', 'web'),
    (9,  8,  'completed',  175.25,  '2024-01-22', 'web'),
    (10, 9,  'completed',  520.00,  '2024-01-23', 'mobile'),
    (11, 10, 'shipped',    88.50,   '2024-01-25', 'web'),
    (12, 1,  'completed',  199.99,  '2024-01-27', 'web'),
    (13, 2,  'completed',  45.00,   '2024-01-28', 'mobile'),
    (14, 3,  'cancelled',  300.00,  '2024-01-29', 'web'),
    (15, 5,  'completed',  215.00,  '2024-01-30', 'web');

INSERT INTO SELFHEALING_PROD.BRONZE.ORDER_ITEMS (id, order_id, product, quantity, unit_price) VALUES
    (1,  1,  'Laptop Stand',       1,  50.00),
    (2,  1,  'Wireless Mouse',     2,  35.00),
    (3,  1,  'USB Hub',            1,  130.00),
    (4,  2,  'Keyboard',           1,  89.99),
    (5,  3,  'Monitor',            1,  380.00),
    (6,  3,  'HDMI Cable',         2,  25.25),
    (7,  4,  'Webcam',             1,  120.00),
    (8,  5,  'Mouse Pad',          1,  55.00),
    (9,  6,  'Headphones',         1,  199.00),
    (10, 6,  'Phone Stand',        2,  55.875),
    (11, 7,  'USB-C Cable',        3,  33.00),
    (12, 8,  'Mechanical Keyboard',1,  280.00),
    (13, 8,  'Desk Mat',           1,  360.00),
    (14, 9,  'Laptop Bag',         1,  175.25),
    (15, 10, 'External SSD',       1,  520.00),
    (16, 11, 'Screen Cleaner',     2,  44.25),
    (17, 12, 'Webcam',             1,  199.99),
    (18, 13, 'Mouse Pad',          1,  45.00),
    (19, 14, 'Monitor Arm',        1,  300.00),
    (20, 15, 'Cable Management',   1,  215.00);
