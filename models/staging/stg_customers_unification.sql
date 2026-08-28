{{ config(materialized='view') }}

with raw_customers as (
    select
        customer_id,
        lower(trim(email)) as normalized_email,
        regexp_replace(phone_number, '[^0-9]', '') as normalized_phone,
        customer_type,
        holdout_group,
        first_seen_date as source_timestamp,
        'raw_shopify.customers' as source_system,
        cast(customer_id as text) as source_id,
        'customer_table' as match_method,
        true as is_known_customer,
        'known_customer' as merge_reason
    from {{ source('shopify', 'customers') }}
),

raw_ga4 as (
    select
        e.ga_user_id as customer_id,
        null as normalized_email,
        null as normalized_phone,
        null as customer_type,
        null as holdout_group,
        min(cast(e.event_timestamp as timestamp)) as source_timestamp,
        'raw_ga4.ga4events' as source_system,
        lower(trim(e.ga_user_id)) as source_id,
        case when c.customer_id is not null then 'customer_id_match' else 'unknown' end as match_method,
        c.customer_id is not null as is_known_customer,
        case when c.customer_id is not null then 'customer_id_match' else 'unknown' end as merge_reason
    from {{ source('ga4', 'ga4events') }} as e
    left join raw_customers as c
      on e.ga_user_id = c.customer_id
    group by 1, 7, 8, 9, 10, 11
),

raw_meta_pixel as (
    select
        e.fb_external_id as customer_id,
        null as normalized_email,
        null as normalized_phone,
        null as customer_type,
        null as holdout_group,
        min(cast(e.event_time as timestamp)) as source_timestamp,
        'raw_meta_pixel.meta_pixel_events' as source_system,
        lower(trim(e.fb_external_id)) as source_id,
        case when c.customer_id is not null then 'customer_id_match' else 'unknown' end as match_method,
        c.customer_id is not null as is_known_customer,
        case when c.customer_id is not null then 'customer_id_match' else 'unknown' end as merge_reason
    from {{ source('meta_pixel', 'meta_pixel_events') }} as e
    left join raw_customers as c
      on e.fb_external_id = c.customer_id
    group by 1, 7, 8, 9, 10, 11
),

raw_callrail as (
    select
        cust.customer_id,
        null as normalized_email,
        regexp_replace(c.caller_phone_number, '[^0-9]', '') as normalized_phone,
        null as customer_type,
        null as holdout_group,
        min(cast(c.call_datetime as timestamp)) as source_timestamp,
        'raw_callrail.calls' as source_system,
        regexp_replace(c.caller_phone_number, '[^0-9]', '') as source_id,
        case when cust.customer_id is not null then 'phone_match' else 'unknown' end as match_method,
        cust.customer_id is not null as is_known_customer,
        case when cust.customer_id is not null then 'phone_match' else 'unknown' end as merge_reason
    from {{ source('callrail', 'calls') }} as c
    left join raw_customers as cust
      on regexp_replace(c.caller_phone_number, '[^0-9]', '') = cust.normalized_phone
    group by 1, 3, 7, 8, 9, 10, 11
),

raw_helpdesk as (
    select
        cust.customer_id,
        lower(trim(h.from_email)) as normalized_email,
        null as normalized_phone,
        null as customer_type,
        null as holdout_group,
        min(cast(h.received_at as timestamp)) as source_timestamp,
        'raw_helpdesk.inbound_helpdesk_emails' as source_system,
        lower(trim(h.from_email)) as source_id,
        case when cust.customer_id is not null then 'email_match' else 'unknown' end as match_method,
        cust.customer_id is not null as is_known_customer,
        case when cust.customer_id is not null then 'email_match' else 'unknown' end as merge_reason
    from {{ source('helpdesk', 'inbound_helpdesk_emails') }} as h
    left join raw_customers as cust
      on lower(trim(h.from_email)) = cust.normalized_email
    group by 1, 2, 7, 8, 9, 10, 11
),

customer_profiles as (
    select
        coalesce(customer_id, concat(source_system, '|', source_id)) as customer_profile_id,
        customer_id as known_customer_id,
        normalized_email,
        normalized_phone,
        customer_type,
        holdout_group,
        source_system,
        source_id,
        source_timestamp,
        match_method,
        is_known_customer,
        merge_reason
    from raw_customers
    union all
    select
        coalesce(customer_id, concat(source_system, '|', source_id)) as customer_profile_id,
        customer_id as known_customer_id,
        normalized_email,
        normalized_phone,
        customer_type,
        holdout_group,
        source_system,
        source_id,
        source_timestamp,
        match_method,
        is_known_customer,
        merge_reason
    from raw_ga4
    union all
    select
        coalesce(customer_id, concat(source_system, '|', source_id)) as customer_profile_id,
        customer_id as known_customer_id,
        normalized_email,
        normalized_phone,
        customer_type,
        holdout_group,
        source_system,
        source_id,
        source_timestamp,
        match_method,
        is_known_customer,
        merge_reason
    from raw_meta_pixel
    union all
    select
        coalesce(customer_id, concat(source_system, '|', source_id)) as customer_profile_id,
        customer_id as known_customer_id,
        normalized_email,
        normalized_phone,
        customer_type,
        holdout_group,
        source_system,
        source_id,
        source_timestamp,
        match_method,
        is_known_customer,
        merge_reason
    from raw_callrail
    union all
    select
        coalesce(customer_id, concat(source_system, '|', source_id)) as customer_profile_id,
        customer_id as known_customer_id,
        normalized_email,
        normalized_phone,
        customer_type,
        holdout_group,
        source_system,
        source_id,
        source_timestamp,
        match_method,
        is_known_customer,
        merge_reason
    from raw_helpdesk
),

-- customer_type/holdout_group only ever come from the raw_shopify.customers
-- branch, the other 4 branches null them out. Backfill from any row in the
-- same customer_profile_id partition instead of relying on which branch
-- wins the row_number() tie below: stg_touchpoints.sql looks up specific
-- (source_system, source_id) rows from this model's final output, so the
-- tie-break below has to stay free to let a ga4/meta_pixel row win --
-- otherwise those branches' rows never survive dedup and paid_search/
-- paid_social/organic/email touchpoints stop resolving to a known customer.
customer_profiles_filled as (
    select
        * exclude (customer_type, holdout_group),
        max(customer_type) over (partition by customer_profile_id) as customer_type,
        max(holdout_group) over (partition by customer_profile_id) as holdout_group
    from customer_profiles
)

select
    customer_profile_id,
    known_customer_id,
    normalized_email,
    normalized_phone,
    customer_type,
    holdout_group,
    source_system,
    source_id,
    source_timestamp,
    match_method,
    is_known_customer,
    merge_reason
from (
    select *,
           row_number() over (
               partition by customer_profile_id
               -- source_system is a final deterministic tiebreaker: without
               -- it, a tie on is_known_customer + source_timestamp between
               -- two branches for the same profile has no defined winner,
               -- and was observed to pick differently across separate dbt
               -- build runs against the same static data (surfaced as a
               -- handful of NULL resolved_customer_profile_id rows in
               -- int_attribution_credit that came and went between builds).
               -- (customer_profile_id, source_system) is unique per branch's
               -- own group by, so this always fully resolves the tie.
               order by is_known_customer desc, source_timestamp asc, source_system asc
           ) as rn
    from customer_profiles_filled
)
where rn = 1
