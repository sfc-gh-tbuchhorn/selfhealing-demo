{{
  config(
    database = var('db_name'),
    schema   = 'GOLD'
  )
}}

SELECT
    oi.PRODUCT_NAME,
    COUNT(DISTINCT oi.ITEM_ID)          AS items_sold,
    SUM(oi.QUANTITY)                    AS total_units,
    SUM(oi.QUANTITY * oi.UNIT_PRICE)    AS total_revenue,
    AVG(oi.UNIT_PRICE)                  AS avg_unit_price,
    COUNT(DISTINCT oi.ORDER_ID)         AS order_count
FROM {{ ref('order_items') }} oi
GROUP BY 1