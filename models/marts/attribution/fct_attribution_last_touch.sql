{{ config(
    materialized='view',
    tags=['marts', 'attribution']
) }}

-- Last-touch attribution: 100% of a converting journey's revenue and conversion
-- credit goes to the channel of that journey's last touchpoint.

with last_touch_journeys as (
    select
        journey_id,
        channel,
        order_value
    from {{ ref('int_user_journeys') }}
    where converted = 1
      and is_last_touch = true
)

select
    channel,
    'last_touch' as attribution_method,
    count(distinct journey_id) as attributed_conversions,
    sum(order_value) as attributed_revenue
from last_touch_journeys
group by channel
