{{
  config(
    database = var('db_name'),
    schema   = 'GOLD'
  )
}}

SELECT
    DATE_TRUNC('DAY', o.ORDER_DATE)   AS order_date,
    c.COUNTRY,
    c.SEGMENT,
    o.CHANNEL,
    o.STATUS,
    c.LOYALTY_TIER,
    c.PREFERRED_CONTACT,
    c.PREFERRED_LANGUAGE,
    COUNT(DISTINCT o.ORDER_ID)         AS order_count,
    COUNT(DISTINCT o.CUSTOMER_ID)      AS customer_count,
    SUM(o.TOTAL_AMOUNT)                AS total_revenue,
    AVG(o.TOTAL_AMOUNT)                AS avg_order_value
FROM {{ ref('orders') }}    o
JOIN {{ ref('customers') }} c
  ON o.CUSTOMER_ID = c.CUSTOMER_ID
GROUP BY 1,2,3,4,5,6,7,8