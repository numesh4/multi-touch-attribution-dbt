{{ config(
    materialized='view',
    tags=['marts', 'attribution']
) }}

-- Time-decay attribution: touchpoints closer to conversion get more credit,
-- via exponential decay with a 7-day half-life (median time-to-conversion in
-- this data is 4 days, p90 is 14 days, so a touch a week out earns half the
-- credit of one on the conversion day, and a touch two weeks out earns a
-- quarter). Raw weights are normalized within each journey so credit still
-- sums to 1 per converting journey.

with raw_weights as (
    select
        journey_id,
        channel,
        order_value,
        power(0.5, days_to_conversion / 7.0) as raw_weight
    from {{ ref('int_user_journeys') }}
    where converted = 1
),

normalized_weights as (
    select
        channel,
        order_value,
        raw_weight / sum(raw_weight) over (partition by journey_id) as credit_weight
    from raw_weights
)

select
    channel,
    'time_decay' as attribution_method,
    sum(credit_weight) as attributed_conversions,
    sum(order_value * credit_weight) as attributed_revenue
from normalized_weights
group by channel
