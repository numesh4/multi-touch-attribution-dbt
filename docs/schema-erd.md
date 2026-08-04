# Source schema

Entity relationship diagram of the five raw source tables and how they connect.

```mermaid
erDiagram
  CUSTOMERS ||--o{ ORDERS : "places"
  CUSTOMERS ||--o{ EVENTS : "generates"
  EVENTS }o--o{ GOOGLE_ADS_COSTS : "joins_on_channel_date"
  EVENTS }o--o{ META_ADS_COSTS : "joins_on_channel_date"
  CUSTOMERS {
    string customer_id PK
    string customer_type
    date first_seen_date
  }
  ORDERS {
    string order_id PK
    string customer_id FK
    timestamp created_at
    float total_price
  }
  EVENTS {
    string event_id PK
    string ga_user_id FK
    string traffic_source
    string campaign_name
    timestamp event_timestamp
  }
  GOOGLE_ADS_COSTS {
    date cost_date
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

**Note on the cost tables:** `google_ads_costs` and `meta_ads_costs` don't share a customer or event key with anything else, they're daily aggregates. They join to `events` on `channel` + `date` instead, a many-to-many relationship, not a true foreign key. This is why `stg_costs` has to explicitly union and normalize both tables before "cost" becomes one consistent concept downstream.

---

## Layered schema view (raw → staging → intermediate → marts)

The diagram below shows the intended raw/staging/intermediate/mart architecture: how raw source tables (in DuckDB or a data warehouse) flow into per-source staging models, a canonical staging union (`stg_touchpoints`), intermediate journey stitching, and final attribution marts. Use this as a guide when organizing models and tests at each layer.

```mermaid
flowchart LR
  subgraph Raw["Raw — DuckDB / source layer"]
    raw_ga4[raw_ga4.ga4events]
    raw_meta[raw_meta_pixel.meta_pixel_events]
    raw_callrail[raw_callrail.calls]
    raw_helpdesk[raw_helpdesk.inbound_helpdesk_emails]
    raw_shopify_orders[raw_shopify.shopify_orders]
    raw_shopify_customers[raw_shopify.customers]
    raw_google[raw_google_ads.google_campaign_costs]
    raw_meta_ads[raw_meta_ads.meta_ad_insights]
  end

  subgraph Staging["Staging (dbt models)"]
    stg_touchpoints[stg_touchpoints]
  end

  subgraph Intermediate["Intermediate / planned models"]
    int_journeys[int_user_journeys]
    int_sessions[int_user_sessions]
  end

  subgraph Marts["Marts / planned models"]
    fct_first[fct_attribution_first_touch]
    fct_last[fct_attribution_last_touch]
    fct_linear[fct_attribution_linear]
    fct_time_decay[fct_attribution_time_decay]
    fct_summary[fct_attribution_summary]
    fct_incrementality[fct_incrementality_vs_attribution]
  end

  %% Raw source tables -> canonical staging
  raw_ga4 --> stg_touchpoints
  raw_meta --> stg_touchpoints
  raw_callrail --> stg_touchpoints
  raw_helpdesk --> stg_touchpoints
  raw_shopify_customers --> stg_touchpoints

  %% Canonical staging -> intermediate -> marts
  stg_touchpoints --> int_journeys
  stg_touchpoints --> int_sessions

  int_journeys --> fct_first
  int_journeys --> fct_last
  int_journeys --> fct_linear
  int_journeys --> fct_time_decay
  int_journeys --> fct_incrementality

  fct_first --> fct_summary
  fct_last --> fct_summary
  fct_linear --> fct_summary
  fct_time_decay --> fct_summary
```

Notes:
- Raw: physical tables/files that arrive from source systems (DuckDB in dev, Snowflake/BigQuery in production). The current raw tables include the GA4, Meta Pixel, CallRail, Helpdesk, Shopify customer/order, and cost tables.
- Staging: your current dbt model in this repo is `stg_touchpoints`, which unifies the raw source tables used by the current project into one canonical touchpoint schema. The current implementation pulls from `raw_ga4.ga4events`, `raw_meta_pixel.meta_pixel_events`, `raw_callrail.calls`, `raw_helpdesk.inbound_helpdesk_emails`, and `raw_shopify.customers`.
- Intermediate: planned models such as `int_user_journeys` and `int_user_sessions` would sit here once implemented.
- Marts: planned attribution models such as `fct_attribution_first_touch`, `fct_attribution_last_touch`, `fct_attribution_linear`, `fct_attribution_time_decay`, `fct_attribution_summary`, and `fct_incrementality_vs_attribution` would sit here once implemented.

This layered view makes it clear where to place tests and transformations: schema tests on `stg_touchpoints` today, and business-rule tests on intermediate/mart models as those layers are built.