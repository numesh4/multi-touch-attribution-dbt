{{ config(materialized='view') }}

-- Canonical conversions staging model
-- Normalizes Shopify orders into a simple conversions view used by downstream models

select
  cast(o.order_id as text) as order_id,
  cast(o.customer_id as text) as user_id,
  cast(o.created_at as timestamp) as conversion_timestamp,
  cast(o.total_price as decimal(12,2)) as revenue,
  cust.email as customer_email,
  cust.phone_number as customer_phone,
  cu.customer_profile_id as customer_profile_id,
  cu.match_method as match_method,
  'raw_shopify.shopify_orders' as raw_source,
  row_number() over (partition by o.customer_id order by o.created_at) > 1 as is_repeat_purchase
from {{ source('shopify','shopify_orders') }} as o
left join {{ ref('stg_customers_unification') }} as cu
  on o.customer_id = cu.known_customer_id
left join {{ source('shopify','customers') }} as cust
  on o.customer_id = cust.customer_id
