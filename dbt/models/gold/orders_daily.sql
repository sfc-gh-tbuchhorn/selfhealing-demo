{{ config(materialized='table') }}

SELECT 
  DATE_TRUNC('DAY', o.ORDER_DATE) AS order_date, 
  c.COUNTRY, 
  c.SEGMENT, 
  o.CHANNEL, 
  o.STATUS, 
  o.DISCOUNT_CODE,
  COUNT(DISTINCT o.ORDER_ID) AS order_count, 
  COUNT(DISTINCT o.CUSTOMER_ID) AS customer_count, 
  SUM(o.TOTAL_AMOUNT) AS total_revenue, 
  AVG(o.TOTAL_AMOUNT) AS avg_order_value 
FROM 
  SELFHEALING_PROD.SILVER.ORDERS o 
  JOIN SELFHEALING_PROD.SILVER.CUSTOMERS c 
    ON o.CUSTOMER_ID = c.CUSTOMER_ID 
GROUP BY 
  1,2,3,4,5,6