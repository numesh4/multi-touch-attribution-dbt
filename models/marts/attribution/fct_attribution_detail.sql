{{ config(
    materialized='view',
    tags=['marts', 'attribution']
) }}

-- Granular attribution detail: one row per touchpoint per attribution method,
-- with the customer and journey it belongs to. This is the row-level source
-- the fct_attribution_* channel marts and fct_attribution_summary roll up --
-- use this mart directly for "revenue per customer" or "revenue per journey"
-- cuts that channel-level reporting collapses away.

select
    journey_id,
    platform_id,
    shopify_customer_id,
    resolved_known_customer_id,
    resolved_customer_profile_id,
    customer_type,
    channel,
    campaign,
    event_timestamp,
    touchpoint_sequence,
    total_touches_in_journey,
    days_to_conversion,
    order_value,
    attribution_method,
    credit_weight,
    attributed_revenue
from {{ ref('int_attribution_credit') }}
