{{ config(
    materialized='view',
    tags=['marts', 'attribution']
) }}

-- First-touch attribution: 100% of a converting journey's revenue and conversion
-- credit goes to the channel of that journey's first touchpoint.

with first_touch_journeys as (
    select
        journey_id,
        channel,
        order_value
    from {{ ref('int_user_journeys') }}
    where converted = 1
      and is_first_touch = true
)

select
    channel,
    'first_touch' as attribution_method,
    count(distinct journey_id) as attributed_conversions,
    sum(order_value) as attributed_revenue
from first_touch_journeys
group by channel
