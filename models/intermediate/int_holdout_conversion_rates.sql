{{ config(
    materialized='table',
    tags=['intermediate', 'incrementality']
) }}

-- One row per holdout_group ('treatment'/'control'). Rolls int_user_journeys
-- up to customer grain first (a journey's order_value/converted flag repeats
-- once per touchpoint row, so it must be deduped to journey grain before
-- summing), then joins to stg_customers_unification for the group assignment
-- build_source_data.py made at generation time. Feeds
-- fct_incrementality_vs_attribution's holdout-lift calculation.
--
-- Materialized as a table, same reasoning as int_attribution_credit: this
-- reads through int_user_journeys' full identity-resolution chain (which
-- itself passes through several correlated subqueries in stg_touchpoints),
-- and fct_incrementality_vs_attribution's own tests would otherwise re-run
-- that whole chain per test.

with customer_journeys as (
    select distinct
        journey_id,
        resolved_customer_profile_id,
        converted,
        order_value
    from {{ ref('int_user_journeys') }}
),

customer_facts as (
    select
        resolved_customer_profile_id,
        count(distinct case when converted = 1 then journey_id end) as converting_journeys,
        sum(case when converted = 1 then order_value else 0 end) as total_revenue
    from customer_journeys
    group by resolved_customer_profile_id
),

customer_holdout as (
    select
        cf.resolved_customer_profile_id,
        cu.holdout_group,
        case when cf.converting_journeys > 0 then 1 else 0 end as has_converted,
        cf.converting_journeys,
        cf.total_revenue
    from customer_facts cf
    inner join {{ ref('stg_customers_unification') }} cu
        on cf.resolved_customer_profile_id = cu.customer_profile_id
    -- unresolved touchpoint identities (no Shopify match) were never
    -- assigned a holdout_group and aren't part of the experiment population
    where cu.holdout_group is not null
)

select
    holdout_group,
    count(*) as customers,
    sum(has_converted) as converting_customers,
    sum(has_converted) * 1.0 / count(*) as conversion_rate,
    sum(converting_journeys) as total_conversions,
    sum(total_revenue) as total_revenue,
    sum(total_revenue) / count(*) as revenue_per_customer
from customer_holdout
group by holdout_group
