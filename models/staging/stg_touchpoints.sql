{{ config(materialized='view') }}

with ga4 as (
    select
        concat('ga4|', cast(event_id as text)) as platform_id,
        ga_user_id as user_id,
        traffic_source as channel,
        campaign_name as campaign,
        cast(event_timestamp as timestamp) as event_timestamp,
        'raw_ga4.ga4events' as raw_source,
        null as raw_identifier
    from {{ source('ga4', 'ga4events') }}
),

meta_pixel as (
    select
        concat('meta_pixel|', cast(pixel_event_id as text)) as platform_id,
        fb_external_id as user_id,
        'paid_social' as channel,
        campaign_name as campaign,
        cast(event_time as timestamp) as event_timestamp,
        'raw_meta_pixel.meta_pixel_events' as raw_source,
        null as raw_identifier
    from {{ source('meta_pixel', 'meta_pixel_events') }}
),

callrail as (
    select
        concat('callrail|', cast(call_id as text)) as platform_id,
        cust.customer_id as user_id,
        'phone' as channel,
        source_campaign as campaign,
        cast(call_datetime as timestamp) as event_timestamp,
        'raw_callrail.calls' as raw_source,
        caller_phone_number as raw_identifier
    from {{ source('callrail', 'calls') }} as c
    left join {{ source('shopify', 'customers') }} as cust
      on c.caller_phone_number = cust.phone_number
),

helpdesk as (
    select
        concat('helpdesk|', cast(ticket_id as text)) as platform_id,
        cust.customer_id as user_id,
        'email_inbound' as channel,
        subject_category as campaign,
        cast(received_at as timestamp) as event_timestamp,
        'raw_helpdesk.inbound_helpdesk_emails' as raw_source,
        lower(from_email) as raw_identifier
    from {{ source('helpdesk', 'inbound_helpdesk_emails') }} as h
    left join {{ source('shopify', 'customers') }} as cust
      on lower(h.from_email) = lower(cust.email)
)

select * from ga4
union all
select * from meta_pixel
union all
select * from callrail
union all
select * from helpdesk
