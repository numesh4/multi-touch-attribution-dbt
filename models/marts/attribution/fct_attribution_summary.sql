{{ config(
    materialized='view',
    tags=['marts', 'attribution']
) }}

-- All four attribution methods side by side, grained on (channel, attribution_method).
-- Summing attributed_revenue across the whole table double/quadruple-counts the
-- same underlying revenue under different methods -- filter to a single
-- attribution_method (e.g. in a BI tool) to get a coherent view. See
-- docs/docs_data_methodology.md.

select
    channel,
    attribution_method,
    sum(credit_weight) as attributed_conversions,
    sum(attributed_revenue) as attributed_revenue
from {{ ref('int_attribution_credit') }}
group by channel, attribution_method
