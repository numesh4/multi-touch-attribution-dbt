--could potentially be table, but view is more efficient for this intermediate step
{{ config(
    materialized='view',    
    tags=['intermediate']
) }}

with touchpoints as (
    select 
        *
    from {{ ref('stg_touchpoints') }}
),

conversions as (
    select
        *,
        lag(conversion_timestamp) over (
            partition by user_id order by conversion_timestamp
        ) as previous_order_timestamp
    from {{ ref('stg_conversions') }}
),

customer_unification as (
    select 
        customer_profile_id,
        known_customer_id,
        customer_type,
        match_method,
        source_system
    from {{ ref('stg_customers_unification') }}
),

-- converting journeys: each order, all touches from that customer before order/purchase date
converting_journeys as (
    select 
        c.order_id as journey_id,
        c.user_id as shopify_customer_id,
        c.conversion_timestamp as journey_end_date,
        t.platform_id,
        t.resolved_known_customer_id,
        t.resolved_customer_profile_id,
        t.match_method as touchpoint_match_method,
        cu.customer_type,
        cu.source_system as profile_source_system,
        t.channel,
        t.campaign,
        t.event_timestamp,
        t.raw_source,
        t.raw_identifier,
        1 as converted,
        c.revenue as order_value,
        c.is_repeat_purchase
    from conversions c
    inner join touchpoints t
        on c.user_id = t.resolved_known_customer_id
        and t.event_timestamp <= c.conversion_timestamp
        and (c.previous_order_timestamp is null or t.event_timestamp > c.previous_order_timestamp)
    left join customer_unification cu
        on t.resolved_customer_profile_id = cu.customer_profile_id
),

-- identify all profiles that have at least one converting order
converted_profiles as (
    select distinct resolved_customer_profile_id
    from converting_journeys
),

-- non-converting journeys: all touches from profiles with no orders/purchases
non_converting_journeys as (
   select 
        concat(t.resolved_customer_profile_id, '_no_conversion') as journey_id,
        null as shopify_customer_id,
        max(t.event_timestamp) as journey_end_date,
        t.platform_id,
        t.resolved_known_customer_id,
        t.resolved_customer_profile_id,
        t.match_method as touchpoint_match_method,
        cu.customer_type,
        cu.source_system as profile_source_system,
        t.channel,
        t.campaign,
        t.event_timestamp,
        t.raw_source,
        t.raw_identifier,
        0 as converted,
        null as order_value,
        null as is_repeat_purchase
    from touchpoints t
    left join customer_unification cu
        on t.resolved_customer_profile_id = cu.customer_profile_id
    where t.resolved_customer_profile_id not in (select resolved_customer_profile_id from converted_profiles)
    group by t.platform_id, t.resolved_known_customer_id, t.resolved_customer_profile_id, 
             t.match_method, cu.customer_type, cu.source_system, t.channel, t.campaign, 
             t.event_timestamp, t.raw_source, t.raw_identifier
),

-- union converting and non-converting
unioned as (
    select * from converting_journeys
    union all
    select * from non_converting_journeys
),

-- add ordinal position and time-based metadata
with_ordinal_position as (
    select 
        *,
        row_number() over (partition by journey_id order by event_timestamp) as touchpoint_sequence,
        lag(event_timestamp) over (partition by journey_id order by event_timestamp) as previous_touch_timestamp,
        lead(event_timestamp) over (partition by journey_id order by event_timestamp) as next_touch_timestamp,
        datediff('day', event_timestamp, journey_end_date) as days_to_conversion,
        count(*) over (partition by journey_id) as total_touches_in_journey,
        datediff('second', lag(event_timestamp) over (partition by journey_id order by event_timestamp), event_timestamp) as seconds_since_previous_touch
    from unioned
)

select 
    *,
    case 
        when touchpoint_sequence = 1 then true 
        else false 
    end as is_first_touch,
    case 
        when touchpoint_sequence = total_touches_in_journey then true 
        else false 
    end as is_last_touch,
    case
        when total_touches_in_journey = 1 then true
        else false
    end as is_single_touch_journey
from with_ordinal_position