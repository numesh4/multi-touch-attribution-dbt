{{ config(materialized='view') }}

with ga4 as (
    select
        concat('ga4|', cast(e.event_id as text)) as platform_id,
        -- look up a known customer mapping if one exists in the unification model
        (select known_customer_id from {{ ref('stg_customers_unification') }} cu
            where cu.source_system = 'raw_ga4.ga4events' and cu.source_id = lower(trim(e.ga_user_id::text))
            limit 1) as resolved_known_customer_id,
        (select customer_profile_id from {{ ref('stg_customers_unification') }} cu
            where cu.source_system = 'raw_ga4.ga4events' and cu.source_id = lower(trim(e.ga_user_id::text))
            limit 1) as resolved_customer_profile_id,
        (select match_method from {{ ref('stg_customers_unification') }} cu
            where cu.source_system = 'raw_ga4.ga4events' and cu.source_id = lower(trim(e.ga_user_id::text))
            limit 1) as match_method,
        e.traffic_source as channel,
        e.campaign_name as campaign,
        cast(e.event_timestamp as timestamp) as event_timestamp,
        'raw_ga4.ga4events' as raw_source,
        e.ga_user_id as raw_identifier
    from {{ source('ga4', 'ga4events') }} as e
),

meta_pixel as (
    select
        concat('meta_pixel|', cast(pixel_event_id as text)) as platform_id,
        -- attempt to resolve known customer via customer_profile source mapping
        (select known_customer_id from {{ ref('stg_customers_unification') }} cu
            where cu.source_system = 'raw_meta_pixel.meta_pixel_events'
              and cu.source_id = lower(trim(m.fb_external_id::text))
            limit 1) as resolved_known_customer_id,
        (select customer_profile_id from {{ ref('stg_customers_unification') }} cu
            where cu.source_system = 'raw_meta_pixel.meta_pixel_events'
              and cu.source_id = lower(trim(m.fb_external_id::text))
            limit 1) as resolved_customer_profile_id,
        (select match_method from {{ ref('stg_customers_unification') }} cu
            where cu.source_system = 'raw_meta_pixel.meta_pixel_events'
              and cu.source_id = lower(trim(m.fb_external_id::text))
            limit 1) as match_method,
        'paid_social' as channel,
        campaign_name as campaign,
        cast(event_time as timestamp) as event_timestamp,
        'raw_meta_pixel.meta_pixel_events' as raw_source,
        null as raw_identifier
    from {{ source('meta_pixel', 'meta_pixel_events') }} as m
),

callrail as (
    select
        concat('callrail|', cast(c.call_id as text)) as platform_id,
        custu.known_customer_id as resolved_known_customer_id,
        custu.customer_profile_id as resolved_customer_profile_id,
        custu.match_method as match_method,
        'phone' as channel,
        c.source_campaign as campaign,
        cast(c.call_datetime as timestamp) as event_timestamp,
        'raw_callrail.calls' as raw_source,
        c.caller_phone_number as raw_identifier
    from {{ source('callrail', 'calls') }} as c
    left join {{ ref('stg_customers_unification') }} as custu
      on regexp_replace(c.caller_phone_number, '[^0-9]', '') = custu.normalized_phone
),

helpdesk as (
    select
        concat('helpdesk|', cast(h.ticket_id as text)) as platform_id,
        custu.known_customer_id as resolved_known_customer_id,
        custu.customer_profile_id as resolved_customer_profile_id,
        custu.match_method as match_method,
        'email_inbound' as channel,
        h.subject_category as campaign,
        cast(h.received_at as timestamp) as event_timestamp,
        'raw_helpdesk.inbound_helpdesk_emails' as raw_source,
        lower(h.from_email) as raw_identifier
    from {{ source('helpdesk', 'inbound_helpdesk_emails') }} as h
    left join {{ ref('stg_customers_unification') }} as custu
      on lower(h.from_email) = custu.normalized_email
)

select * from ga4
union all
select * from meta_pixel
union all
select * from callrail
union all
select * from helpdesk
