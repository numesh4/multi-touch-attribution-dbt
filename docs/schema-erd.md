# Source schema

Entity relationship diagram of the eight raw source tables and how they connect.

```mermaid
erDiagram
  CUSTOMERS ||--o{ ORDERS : "places"
  CUSTOMERS ||--o{ GA4_EVENTS : "customer_id match"
  CUSTOMERS ||--o{ META_PIXEL_EVENTS : "customer_id match"
  CUSTOMERS |o--o{ CALLS : "phone number match, not a shared key"
  CUSTOMERS |o--o{ HELPDESK_EMAILS : "email match, not a shared key"
  GA4_EVENTS }o--o{ GOOGLE_ADS_COSTS : "joins_on_channel_date (planned: stg_costs)"
  META_PIXEL_EVENTS }o--o{ META_ADS_COSTS : "joins_on_channel_date (planned: stg_costs)"
  CUSTOMERS {
    string customer_id PK
    string customer_type
    date first_seen_date
    string phone_number
    string email
  }
  ORDERS {
    string order_id PK
    string customer_id FK
    timestamp created_at
    float total_price
  }
  GA4_EVENTS {
    string event_id PK
    string ga_user_id FK
    string traffic_source
    string campaign_name
    timestamp event_timestamp
  }
  META_PIXEL_EVENTS {
    string pixel_event_id PK
    string fb_external_id FK
    string campaign_name
    timestamp event_time
  }
  CALLS {
    string call_id PK
    string tracking_phone_number
    string caller_phone_number
    timestamp call_datetime
    int duration_seconds
    string direction
    string source_campaign
  }
  HELPDESK_EMAILS {
    string ticket_id PK
    string from_email
    timestamp received_at
    string subject_category
  }
  GOOGLE_ADS_COSTS {
    date date
    string channel_name
    int cost_micros_equivalent
  }
  META_ADS_COSTS {
    date date_start
    string campaign_group
    float spend
    int impressions
    int clicks
  }
```

**Note on identity matching:** `GA4_EVENTS` and `META_PIXEL_EVENTS` carry a customer ID directly (`ga_user_id`, `fb_external_id`), so they resolve to `CUSTOMERS` with a clean, if loosely-typed, key match. `CALLS` and `HELPDESK_EMAILS` carry no customer ID at all, they're matched to `CUSTOMERS` by a digit-normalized phone number or a lowercased/trimmed email address instead, a genuinely weaker join than a foreign key. `stg_customers_unification` is where all four of these matching strategies actually get implemented and reconciled into one `customer_profile_id`.

**Note on the cost tables:** `google_ads_costs` and `meta_ads_costs` don't share a customer or event key with anything else, they're daily aggregates. They join to touchpoints on `channel` + `date`, a many-to-many relationship, not a true foreign key. `stg_costs` normalizes both tables into one consistent "cost" concept (including converting Google Ads' cost-in-micros to standard currency); see the layered view below.

---

## Layered schema view (raw → staging → intermediate → marts)

The diagram below shows the raw/staging/intermediate/mart architecture: how raw source tables (in DuckDB, standing in for a data warehouse) flow into per-concern staging models, an intermediate journey model, and the (still-planned) attribution marts. Use this as a guide when organizing models and tests at each layer.

```mermaid
flowchart LR
  subgraph Raw["Raw — DuckDB / source layer"]
    raw_ga4[raw_ga4.ga4events]
    raw_meta_pixel[raw_meta_pixel.meta_pixel_events]
    raw_callrail[raw_callrail.calls]
    raw_helpdesk[raw_helpdesk.inbound_helpdesk_emails]
    raw_shopify_customers[raw_shopify.customers]
    raw_shopify_orders[raw_shopify.shopify_orders]
    raw_google[raw_google_ads.google_campaign_costs]
    raw_meta_ads[raw_meta_ads.meta_ad_insights]
  end

  subgraph Staging["Staging (dbt models)"]
    stg_customers[stg_customers_unification]
    stg_touchpoints[stg_touchpoints]
    stg_conversions[stg_conversions]
    stg_costs[stg_costs]
  end

  subgraph Intermediate["Intermediate"]
    int_journeys[int_user_journeys]
    int_sessions["int_user_sessions (planned)"]
  end

  subgraph Marts["Marts"]
    fct_first[fct_attribution_first_touch]
    fct_last[fct_attribution_last_touch]
    fct_linear[fct_attribution_linear]
    fct_time_decay[fct_attribution_time_decay]
    fct_summary["fct_attribution_summary (planned)"]
    fct_incrementality["fct_incrementality_vs_attribution (planned)"]
  end

  %% Raw source tables -> stg_customers_unification (identity resolution)
  raw_shopify_customers --> stg_customers
  raw_ga4 --> stg_customers
  raw_meta_pixel --> stg_customers
  raw_callrail --> stg_customers
  raw_helpdesk --> stg_customers

  %% Raw touchpoint tables + identity resolution -> stg_touchpoints
  raw_ga4 --> stg_touchpoints
  raw_meta_pixel --> stg_touchpoints
  raw_callrail --> stg_touchpoints
  raw_helpdesk --> stg_touchpoints
  stg_customers --> stg_touchpoints

  %% Raw order/customer tables + identity resolution -> stg_conversions
  raw_shopify_orders --> stg_conversions
  raw_shopify_customers --> stg_conversions
  stg_customers --> stg_conversions

  %% Raw cost tables -> stg_costs
  raw_google --> stg_costs
  raw_meta_ads --> stg_costs

  %% Staging -> intermediate
  stg_touchpoints --> int_journeys
  stg_conversions --> int_journeys
  stg_customers --> int_journeys
  stg_touchpoints --> int_sessions

  %% Intermediate + costs -> marts
  int_journeys --> fct_first
  int_journeys --> fct_last
  int_journeys --> fct_linear
  int_journeys --> fct_time_decay
  int_journeys --> fct_incrementality
  stg_costs --> fct_summary

  fct_first --> fct_summary
  fct_last --> fct_summary
  fct_linear --> fct_summary
  fct_time_decay --> fct_summary
```

Notes:
- Raw: physical tables loaded directly into DuckDB by `build_source_data.py` (standing in for Snowflake/BigQuery in production), bypassing `dbt seed` entirely, the same way an EL tool would land them. Eight tables across seven schemas: `raw_ga4.ga4events`, `raw_meta_pixel.meta_pixel_events`, `raw_callrail.calls`, `raw_helpdesk.inbound_helpdesk_emails`, `raw_shopify.customers`, `raw_shopify.shopify_orders`, `raw_google_ads.google_campaign_costs`, `raw_meta_ads.meta_ad_insights`.
- Staging: four models are built and validated today. `stg_customers_unification` resolves the four touchpoint sources and the orders source against `raw_shopify.customers` into one `customer_profile_id` per person (see `docs/docs_data_methodology.md` for the matching logic). `stg_touchpoints` unions the four touchpoint sources into one canonical touchpoint schema, resolved against `stg_customers_unification`. `stg_conversions` normalizes `raw_shopify.shopify_orders` into a canonical conversions table, also resolved against `stg_customers_unification`. `stg_costs` normalizes the two cost sources, including the Google Ads micros conversion, into one canonical cost concept.
- Intermediate: `int_user_journeys` is built, it stitches every touchpoint before an order into a converting journey, and groups touchpoints from non-converting profiles into a non-converting journey, with ordinal position, time-since-previous-touch, and first/last-touch flags computed per touch. `int_user_sessions` is planned but not yet built.
- Marts: four attribution marts are built — `fct_attribution_first_touch`, `fct_attribution_last_touch`, `fct_attribution_linear`, and `fct_attribution_time_decay`. `fct_attribution_summary` (unions all four) and `fct_incrementality_vs_attribution` are still planned.

This layered view makes it clear where to place tests and transformations: schema and relationship tests on the staging layer (already in place for `stg_touchpoints`, `stg_conversions`, `stg_customers_unification`, `stg_costs`, and `int_user_journeys`), and business-rule tests on the mart layer as it gets built (not-null/unique tests already in place for the four built attribution marts).
