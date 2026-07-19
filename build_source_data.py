"""
build_source_data.py

Loads synthetic marketing attribution data directly into DuckDB as four
separate raw schemas, each standing in for a different real-world source
system that would normally be landed by an EL tool (Fivetran, Airbyte, or
a custom API extract script), not by dbt.

Schemas:
    raw_ga4.events                  <- GA4 / Segment export        (touchpoints)
    raw_shopify.orders              <- Shopify / orders DB export  (conversions)
    raw_shopify.customers           <- Shopify / CRM customer export (B2B/B2C segment)
    raw_google_ads.campaign_costs   <- Google Ads API export       (paid_search costs)
    raw_meta_ads.ad_insights        <- Meta Ads API export         (paid_social costs)

B2B vs B2C behavior is deliberately different, matching realistic patterns:
    - B2B: fewer, higher-value orders; longer consideration journeys with more
      touchpoints spread over longer windows; skews toward email/organic/paid_search
      over paid_social (B2B buyers are less influenced by social ads)
    - B2C: higher volume, lower-value orders; shorter, more impulsive journeys;
      more evenly spread across all four channels, including paid_social

Run with:  python build_source_data.py
Requires: dev.duckdb to already exist (run `dbt debug` at least once first),
and this script run from the project root, same folder as dbt_project.yml.
"""

import random
from datetime import datetime, timedelta
from pathlib import Path

import duckdb
import pandas as pd

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

random.seed(42)

DB_PATH = Path("dev.duckdb")

N_USERS = 3000
CHANNELS = ["paid_search", "paid_social", "email", "organic"]

START_DATE = datetime(2025, 7, 1)
END_DATE = datetime(2026, 6, 30)

CUSTOMER_TYPE_WEIGHTS = {"b2c": 0.85, "b2b": 0.15}

SCENARIO_WEIGHTS_B2C = {
    "single_touch": 0.35,
    "multi_touch": 0.35,
    "non_converting": 0.20,
    "repeat_purchaser": 0.08,
    "long_gap": 0.02,
}
SCENARIO_WEIGHTS_B2B = {
    "single_touch": 0.10,
    "multi_touch": 0.35,
    "non_converting": 0.20,
    "repeat_purchaser": 0.15,
    "long_gap": 0.20,
}

CHANNEL_WEIGHTS_B2C = {"paid_search": 0.33, "paid_social": 0.35, "email": 0.14, "organic": 0.18}
CHANNEL_WEIGHTS_B2B = {"paid_search": 0.38, "paid_social": 0.10, "email": 0.27, "organic": 0.25}

CAMPAIGNS_BY_CHANNEL = {
    "paid_search": ["brand_search", "generic_search", "competitor_search"],
    "paid_social": ["prospecting_ig", "retargeting_fb", "lookalike_tiktok"],
    "email": ["newsletter", "abandoned_cart", "win_back"],
    "organic": ["blog", "direct", "referral"],
}

CHANNEL_BASE_DAILY_SPEND = {
    "paid_search": 450,
    "paid_social": 380,
    "email": 40,
    "organic": 0,
}

REVENUE_RANGE_B2C = (35, 420)
REVENUE_RANGE_B2B = (800, 6000)


def random_date(start, end):
    delta_days = (end - start).days
    return start + timedelta(days=random.randint(0, delta_days), seconds=random.randint(0, 86399))


def weighted_channel_choice(customer_type):
    weights = CHANNEL_WEIGHTS_B2B if customer_type == "b2b" else CHANNEL_WEIGHTS_B2C
    channels, w = zip(*weights.items())
    return random.choices(channels, weights=w)[0]


def assign_scenario(customer_type):
    weights = SCENARIO_WEIGHTS_B2B if customer_type == "b2b" else SCENARIO_WEIGHTS_B2C
    scenarios, w = zip(*weights.items())
    return random.choices(scenarios, weights=w)[0]


def assign_customer_type():
    types, w = zip(*CUSTOMER_TYPE_WEIGHTS.items())
    return random.choices(types, weights=w)[0]


def revenue_for(customer_type):
    lo, hi = REVENUE_RANGE_B2B if customer_type == "b2b" else REVENUE_RANGE_B2C
    return round(random.uniform(lo, hi), 2)


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

touchpoints = []
conversions = []
customers = []
touchpoint_id_counter = 1
conversion_id_counter = 1

for user_num in range(1, N_USERS + 1):
    user_id = f"user_{user_num:05d}"
    customer_type = assign_customer_type()
    customers.append((user_id, customer_type, random_date(START_DATE, END_DATE).date()))

    scenario = assign_scenario(customer_type)

    if scenario == "single_touch":
        touch_date = random_date(START_DATE, END_DATE - timedelta(days=2))
        channel = weighted_channel_choice(customer_type)
        campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
        touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, touch_date))
        touchpoint_id_counter += 1
        convert_date = touch_date + timedelta(hours=random.randint(1, 48))
        conversions.append((conversion_id_counter, user_id, convert_date, revenue_for(customer_type)))
        conversion_id_counter += 1

    elif scenario == "multi_touch":
        n_touches = random.randint(2, 6)
        window_days = random.randint(3, 21)
        journey_start = random_date(START_DATE, END_DATE - timedelta(days=window_days + 3))
        touch_dates = sorted(journey_start + timedelta(days=random.uniform(0, window_days))
                              for _ in range(n_touches))
        for td in touch_dates:
            channel = weighted_channel_choice(customer_type)
            campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
            touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, td))
            touchpoint_id_counter += 1
        convert_date = touch_dates[-1] + timedelta(hours=random.randint(1, 72))
        conversions.append((conversion_id_counter, user_id, convert_date, revenue_for(customer_type)))
        conversion_id_counter += 1

    elif scenario == "non_converting":
        n_touches = random.randint(1, 4)
        for _ in range(n_touches):
            td = random_date(START_DATE, END_DATE)
            channel = weighted_channel_choice(customer_type)
            campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
            touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, td))
            touchpoint_id_counter += 1

    elif scenario == "repeat_purchaser":
        n_touches = random.randint(2, 4)
        window_days = random.randint(3, 14)
        journey_start = random_date(START_DATE, END_DATE - timedelta(days=180))
        touch_dates = sorted(journey_start + timedelta(days=random.uniform(0, window_days))
                              for _ in range(n_touches))
        for td in touch_dates:
            channel = weighted_channel_choice(customer_type)
            campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
            touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, td))
            touchpoint_id_counter += 1
        first_convert = touch_dates[-1] + timedelta(hours=random.randint(1, 72))
        conversions.append((conversion_id_counter, user_id, first_convert, revenue_for(customer_type)))
        conversion_id_counter += 1
        n_repeats = random.randint(1, 3)
        last_date = first_convert
        for _ in range(n_repeats):
            gap = timedelta(days=random.randint(20, 60))
            if last_date + gap >= END_DATE:
                break
            re_touch_date = last_date + gap - timedelta(days=random.randint(0, 2))
            channel = weighted_channel_choice(customer_type)
            campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
            touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, re_touch_date))
            touchpoint_id_counter += 1
            repeat_convert_date = last_date + gap
            conversions.append((conversion_id_counter, user_id, repeat_convert_date, revenue_for(customer_type)))
            conversion_id_counter += 1
            last_date = repeat_convert_date

    elif scenario == "long_gap":
        n_touches = random.randint(2, 5)
        window_days = random.randint(30, 90)
        journey_start = random_date(START_DATE, END_DATE - timedelta(days=window_days + 3))
        touch_dates = sorted(journey_start + timedelta(days=random.uniform(0, window_days))
                              for _ in range(n_touches))
        for td in touch_dates:
            channel = weighted_channel_choice(customer_type)
            campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
            touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, td))
            touchpoint_id_counter += 1
        convert_date = touch_dates[-1] + timedelta(hours=random.randint(1, 48))
        conversions.append((conversion_id_counter, user_id, convert_date, revenue_for(customer_type)))
        conversion_id_counter += 1

extra_rapid_rows = []
existing_user_ids = list({t[1] for t in touchpoints})
rapid_sample = random.sample(existing_user_ids, k=int(len(existing_user_ids) * 0.05))
customer_type_lookup = {c[0]: c[1] for c in customers}
for uid in rapid_sample:
    base_date = random_date(START_DATE, END_DATE - timedelta(days=1))
    for _ in range(random.randint(2, 4)):
        channel = weighted_channel_choice(customer_type_lookup[uid])
        campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
        same_day_time = base_date + timedelta(minutes=random.randint(0, 600))
        extra_rapid_rows.append((touchpoint_id_counter, uid, channel, campaign, same_day_time))
        touchpoint_id_counter += 1
touchpoints.extend(extra_rapid_rows)

# ---------------------------------------------------------------------------
# Daily cost data, split by platform (paid_search -> Google Ads, paid_social -> Meta Ads)
# ---------------------------------------------------------------------------

google_ads_costs = []
meta_ads_costs = []
current_date = START_DATE
while current_date <= END_DATE:
    is_weekend = current_date.weekday() >= 5
    seasonal_multiplier = 1.4 if current_date.month in (11, 12) else 1.0
    weekend_multiplier = 0.7 if is_weekend else 1.0

    base = CHANNEL_BASE_DAILY_SPEND["paid_search"]
    spend = round(base * seasonal_multiplier * weekend_multiplier * random.uniform(0.85, 1.15), 2)
    google_ads_costs.append((current_date.date(), "paid_search", spend))

    base = CHANNEL_BASE_DAILY_SPEND["paid_social"]
    spend = round(base * seasonal_multiplier * weekend_multiplier * random.uniform(0.85, 1.15), 2)
    impressions = int(spend * random.uniform(180, 260))
    clicks = int(impressions * random.uniform(0.008, 0.02))
    meta_ads_costs.append((current_date.date(), "prospecting_ig_retargeting_fb_lookalike_tiktok",
                            spend, impressions, clicks))

    current_date += timedelta(days=1)

# ---------------------------------------------------------------------------
# Build DataFrames, matching realistic source-system column naming
# ---------------------------------------------------------------------------

df_events = pd.DataFrame(touchpoints, columns=[
    "event_id", "ga_user_id", "traffic_source", "campaign_name", "event_timestamp"
])

df_orders = pd.DataFrame(conversions, columns=[
    "order_id", "customer_id", "created_at", "total_price"
])

df_customers = pd.DataFrame(customers, columns=[
    "customer_id", "customer_type", "first_seen_date"
])

df_google_costs = pd.DataFrame(google_ads_costs, columns=[
    "date", "channel_name", "cost_micros_equivalent"
])
df_google_costs["cost_micros_equivalent"] = (df_google_costs["cost_micros_equivalent"] * 1_000_000).astype("int64")

df_meta_costs = pd.DataFrame(meta_ads_costs, columns=[
    "date_start", "campaign_group", "spend", "impressions", "clicks"
])

# ---------------------------------------------------------------------------
# Load into DuckDB
# ---------------------------------------------------------------------------

con = duckdb.connect(str(DB_PATH))

con.execute("CREATE SCHEMA IF NOT EXISTS raw_ga4")
con.execute("CREATE SCHEMA IF NOT EXISTS raw_shopify")
con.execute("CREATE SCHEMA IF NOT EXISTS raw_google_ads")
con.execute("CREATE SCHEMA IF NOT EXISTS raw_meta_ads")

con.execute("CREATE OR REPLACE TABLE raw_ga4.events AS SELECT * FROM df_events")
con.execute("CREATE OR REPLACE TABLE raw_shopify.orders AS SELECT * FROM df_orders")
con.execute("CREATE OR REPLACE TABLE raw_shopify.customers AS SELECT * FROM df_customers")
con.execute("CREATE OR REPLACE TABLE raw_google_ads.campaign_costs AS SELECT * FROM df_google_costs")
con.execute("CREATE OR REPLACE TABLE raw_meta_ads.ad_insights AS SELECT * FROM df_meta_costs")

con.close()

n_b2b = sum(1 for c in customers if c[1] == "b2b")
n_b2c = sum(1 for c in customers if c[1] == "b2c")

print("Source data loaded directly into DuckDB (bypassing dbt seed).")
print(f"  Database:  {DB_PATH.resolve()}")
print(f"  raw_ga4.events                 : {len(df_events)} rows")
print(f"  raw_shopify.orders             : {len(df_orders)} rows")
print(f"  raw_shopify.customers          : {len(df_customers)} rows  (b2c: {n_b2c}, b2b: {n_b2b})")
print(f"  raw_google_ads.campaign_costs  : {len(df_google_costs)} rows")
print(f"  raw_meta_ads.ad_insights       : {len(df_meta_costs)} rows")
print()
print("Next: add raw_shopify.customers table to models/staging/_staging__sources.yml")
