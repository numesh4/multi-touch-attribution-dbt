{{ config(
    materialized='view',
    tags=['marts', 'incrementality']
) }}

-- The differentiator artifact: compares what last-touch attribution credits
-- to paid channels against what the treatment/control holdout implies those
-- channels actually caused. A large positive gap means attribution is
-- over-crediting paid spend relative to a randomized baseline. See
-- docs/docs_data_methodology.md for the holdout design and caveats.

with treatment as (
    select * from {{ ref('int_holdout_conversion_rates') }}
    where holdout_group = 'treatment'
),

control as (
    select * from {{ ref('int_holdout_conversion_rates') }}
    where holdout_group = 'control'
),

holdout_lift as (
    select
        t.customers as treatment_customers,
        c.customers as control_customers,
        t.conversion_rate as treatment_conversion_rate,
        c.conversion_rate as control_conversion_rate,
        t.conversion_rate - c.conversion_rate as incremental_conversion_rate,
        (t.conversion_rate - c.conversion_rate) * t.customers as holdout_implied_incremental_conversions,
        (t.revenue_per_customer - c.revenue_per_customer) * t.customers as holdout_implied_incremental_revenue
    from treatment t
    cross join control c
),

paid_attribution as (
    select
        sum(attributed_conversions) as last_touch_attributed_paid_conversions,
        sum(attributed_revenue) as last_touch_attributed_paid_revenue
    from {{ ref('fct_attribution_summary') }}
    where attribution_method = 'last_touch'
      and channel in ('paid_search', 'paid_social')
)

select
    hl.treatment_customers,
    hl.control_customers,
    hl.treatment_conversion_rate,
    hl.control_conversion_rate,
    hl.incremental_conversion_rate,
    hl.holdout_implied_incremental_conversions,
    hl.holdout_implied_incremental_revenue,
    pa.last_touch_attributed_paid_conversions,
    pa.last_touch_attributed_paid_revenue,
    pa.last_touch_attributed_paid_conversions - hl.holdout_implied_incremental_conversions as conversions_gap,
    (pa.last_touch_attributed_paid_conversions - hl.holdout_implied_incremental_conversions)
        / nullif(pa.last_touch_attributed_paid_conversions, 0) as conversions_gap_pct,
    pa.last_touch_attributed_paid_revenue - hl.holdout_implied_incremental_revenue as revenue_gap,
    (pa.last_touch_attributed_paid_revenue - hl.holdout_implied_incremental_revenue)
        / nullif(pa.last_touch_attributed_paid_revenue, 0) as revenue_gap_pct
from holdout_lift hl
cross join paid_attribution pa
