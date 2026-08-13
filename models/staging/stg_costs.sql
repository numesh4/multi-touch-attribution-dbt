{{ config(materialized='view') }}

-- Canonical daily ad spend staging model
-- Normalizes Google Ads and Meta Ads cost exports into one channel/date grain,
-- converting Google Ads' cost-in-micros into standard currency to match Meta's spend units.

with google_ads as (
    select
        date as cost_date,
        channel_name as channel,
        cast(null as text) as campaign,
        cast(cost_micros_equivalent as decimal(12, 2)) / 1000000 as cost,
        cast(null as bigint) as impressions,
        cast(null as bigint) as clicks,
        'raw_google_ads.google_campaign_costs' as raw_source
    from {{ source('google_ads', 'google_campaign_costs') }}
),

meta_ads as (
    select
        date_start as cost_date,
        'paid_social' as channel,
        campaign_group as campaign,
        cast(spend as decimal(12, 2)) as cost,
        impressions,
        clicks,
        'raw_meta_ads.meta_ad_insights' as raw_source
    from {{ source('meta_ads', 'meta_ad_insights') }}
)

select * from google_ads
union all
select * from meta_ads
