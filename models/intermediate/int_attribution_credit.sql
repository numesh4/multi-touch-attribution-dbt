{{ config(
    materialized='table',
    tags=['intermediate', 'attribution']
) }}

-- Per-touchpoint credit for every attribution method, at the finest grain:
-- one row per (journey_id, platform_id, attribution_method). The four
-- fct_attribution_* channel marts, fct_attribution_summary, and
-- fct_attribution_detail all read from this model instead of each
-- recomputing their own weighting logic.
--
-- Materialized as a table (not a view): six downstream models now select
-- from this one, each also carrying its own data tests. As a view, every one
-- of those tests would re-run the full upstream chain -- including
-- int_user_journeys' identity-resolution joins -- from scratch, which turned
-- a normally-fast `dbt build` into a ~20 minute, multi-GB run.

with base as (
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
        is_first_touch,
        is_last_touch
    from {{ ref('int_user_journeys') }}
    where converted = 1
),

first_touch as (
    select
        * exclude (is_first_touch, is_last_touch),
        'first_touch' as attribution_method,
        case when is_first_touch then 1.0 else 0.0 end as credit_weight
    from base
),

last_touch as (
    select
        * exclude (is_first_touch, is_last_touch),
        'last_touch' as attribution_method,
        case when is_last_touch then 1.0 else 0.0 end as credit_weight
    from base
),

linear as (
    select
        * exclude (is_first_touch, is_last_touch),
        'linear' as attribution_method,
        1.0 / total_touches_in_journey as credit_weight
    from base
),

time_decay_raw as (
    select
        * exclude (is_first_touch, is_last_touch),
        power(0.5, days_to_conversion / 7.0) as raw_weight
    from base
),

time_decay as (
    select
        * exclude (raw_weight),
        'time_decay' as attribution_method,
        raw_weight / sum(raw_weight) over (partition by journey_id) as credit_weight
    from time_decay_raw
),

unioned as (
    select * from first_touch
    union all
    select * from last_touch
    union all
    select * from linear
    union all
    select * from time_decay
)

select
    *,
    order_value * credit_weight as attributed_revenue
from unioned
