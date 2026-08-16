{{ config(
    materialized='view',
    tags=['marts', 'attribution']
) }}

-- Linear attribution: each touchpoint in a converting journey gets equal
-- fractional credit (1 / total touches in that journey).

with weighted_touches as (
    select
        journey_id,
        channel,
        order_value,
        1.0 / total_touches_in_journey as credit_weight
    from {{ ref('int_user_journeys') }}
    where converted = 1
)

select
    channel,
    'linear' as attribution_method,
    sum(credit_weight) as attributed_conversions,
    sum(order_value * credit_weight) as attributed_revenue
from weighted_touches
group by channel
