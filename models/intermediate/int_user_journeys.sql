{{ config(materialized='view') }}

with conversions as (
    select
        user_id,
        conversion_id,
        conversion_timestamp,
        revenue,
        row_number() over (
            partition by user_id
            order by conversion_timestamp, conversion_id
        ) as conversion_rank
    from {{ ref('stg_conversions') }}
    where user_id is not null
),

ordered_touchpoints as (
    select
        user_id,
        platform_id,
        channel,
        campaign,
        event_timestamp,
        row_number() over (
            partition by user_id
            order by event_timestamp, platform_id
        ) as touch_sequence
    from {{ ref('stg_touchpoints') }}
    where user_id is not null
 ) /*sequence touchpoints based on timestamp*/

select
    ot.user_id,
    ot.platform_id,
    ot.channel,
    ot.campaign,
    ot.event_timestamp,
    ot.touch_sequence,
    conv.conversion_id,
    conv.conversion_timestamp,
    conv.revenue,
    case
        when conv.conversion_id is not null and ot.event_timestamp <= conv.conversion_timestamp then 1
        else 0
    end as is_before_conversion
from ordered_touchpoints ot
left join conversions conv
    on ot.user_id = conv.user_id
   and conv.conversion_rank = 1
where conv.conversion_id is null
   or ot.event_timestamp <= conv.conversion_timestamp
order by ot.user_id, ot.touch_sequence
