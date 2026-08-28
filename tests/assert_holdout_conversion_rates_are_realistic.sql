-- Fails if either holdout group shows ~0% or ~100% conversion, which would
-- indicate a broken upstream join/filter collapsing the population (this
-- happened once: a NULL-unsafe `not in` in int_user_journeys silently
-- dropped every non-converting journey, and every not_null test on
-- int_holdout_conversion_rates/fct_incrementality_vs_attribution still
-- passed since 1.0 is a valid, non-null value).

select holdout_group, conversion_rate
from {{ ref('int_holdout_conversion_rates') }}
where conversion_rate >= 0.999 or conversion_rate <= 0.001
