"""
generate_synthetic_data.py

Generates synthetic marketing attribution data for the multi-touch-attribution-dbt project.
Produces three CSVs at different grains, matching what a real marketing data warehouse
would typically have:

- raw_touchpoints.csv   : event-grain (one row per touchpoint interaction)
- raw_conversions.csv   : order-grain (one row per conversion/purchase, supports repeat purchases)
- raw_costs.csv         : daily-grain (one row per channel per day)

Journey scenarios included, deliberately, so the attribution models have something
meaningful to differentiate on:
  1. Single-touch converters       (last-touch and first-touch will agree)
  2. Multi-touch converters        (2-6 touches, models will disagree on credit)
  3. Non-converting users          (touchpoints exist, no conversion, needed for
                                    realistic funnel/incrementality analysis)
  4. Repeat purchasers             (multiple conversions per user, for later LTV work)
  5. Long-gap journeys             (touches spread over weeks, tests time-decay logic)
  6. Same-day rapid journeys       (multiple touches same day, tests tie-breaking logic)

Run with:  python generate_synthetic_data.py
Output lands in ./seeds/ by default (adjust OUTPUT_DIR below if needed).
"""

import random
import csv
from datetime import datetime, timedelta
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

random.seed(42)  # reproducible output, delete or change if you want fresh data each run

OUTPUT_DIR = Path("seeds")
OUTPUT_DIR.mkdir(exist_ok=True)

N_USERS = 3000
CHANNELS = ["paid_search", "paid_social", "email", "organic"]

# Date range: 12 months, gives seasonality room for the forecasting module later too
START_DATE = datetime(2025, 7, 1)
END_DATE = datetime(2026, 6, 30)
TOTAL_DAYS = (END_DATE - START_DATE).days

# Journey scenario mix (must sum to 1.0)
SCENARIO_WEIGHTS = {
    "single_touch": 0.30,
    "multi_touch": 0.35,
    "non_converting": 0.20,
    "repeat_purchaser": 0.10,
    "long_gap": 0.05,
}

CAMPAIGNS_BY_CHANNEL = {
    "paid_search": ["brand_search", "generic_search", "competitor_search"],
    "paid_social": ["prospecting_ig", "retargeting_fb", "lookalike_tiktok"],
    "email": ["newsletter", "abandoned_cart", "win_back"],
    "organic": ["blog", "direct", "referral"],
}

# Rough relative cost-per-touch by channel, used to generate plausible daily spend
CHANNEL_BASE_DAILY_SPEND = {
    "paid_search": 450,
    "paid_social": 380,
    "email": 40,      # email is cheap, mostly labor not media spend
    "organic": 0,      # no media spend, included for completeness/benchmarking contrast
}

REVENUE_MIN, REVENUE_MAX = 35, 420  # per-order revenue range


def random_date(start, end):
    delta_days = (end - start).days
    return start + timedelta(days=random.randint(0, delta_days), seconds=random.randint(0, 86399))


def weighted_channel_choice():
    # organic and paid_search get slightly more weight, matches a typical real mix
    return random.choices(CHANNELS, weights=[0.35, 0.30, 0.15, 0.20])[0]


def assign_scenario():
    scenarios, weights = zip(*SCENARIO_WEIGHTS.items())
    return random.choices(scenarios, weights=weights)[0]


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

touchpoints = []
conversions = []

touchpoint_id_counter = 1
conversion_id_counter = 1

for user_num in range(1, N_USERS + 1):
    user_id = f"user_{user_num:05d}"
    scenario = assign_scenario()

    if scenario == "single_touch":
        # one touch, then convert shortly after
        touch_date = random_date(START_DATE, END_DATE - timedelta(days=2))
        channel = weighted_channel_choice()
        campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
        touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, touch_date))
        touchpoint_id_counter += 1

        convert_date = touch_date + timedelta(hours=random.randint(1, 48))
        conversions.append((conversion_id_counter, user_id, convert_date,
                             round(random.uniform(REVENUE_MIN, REVENUE_MAX), 2)))
        conversion_id_counter += 1

    elif scenario == "multi_touch":
        # 2-6 touches across a window of days-to-weeks, then convert
        n_touches = random.randint(2, 6)
        window_days = random.randint(3, 21)
        journey_start = random_date(START_DATE, END_DATE - timedelta(days=window_days + 3))
        touch_dates = sorted(
            journey_start + timedelta(days=random.uniform(0, window_days))
            for _ in range(n_touches)
        )
        for td in touch_dates:
            channel = weighted_channel_choice()
            campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
            touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, td))
            touchpoint_id_counter += 1

        convert_date = touch_dates[-1] + timedelta(hours=random.randint(1, 72))
        conversions.append((conversion_id_counter, user_id, convert_date,
                             round(random.uniform(REVENUE_MIN, REVENUE_MAX), 2)))
        conversion_id_counter += 1

    elif scenario == "non_converting":
        # 1-4 touches, no conversion at all, important for realistic funnel shape
        n_touches = random.randint(1, 4)
        for _ in range(n_touches):
            td = random_date(START_DATE, END_DATE)
            channel = weighted_channel_choice()
            campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
            touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, td))
            touchpoint_id_counter += 1

    elif scenario == "repeat_purchaser":
        # initial multi-touch journey to first conversion, then 1-3 repeat
        # conversions with a single lighter-touch "re-engagement" each time
        n_touches = random.randint(2, 4)
        window_days = random.randint(3, 14)
        journey_start = random_date(START_DATE, END_DATE - timedelta(days=180))
        touch_dates = sorted(
            journey_start + timedelta(days=random.uniform(0, window_days))
            for _ in range(n_touches)
        )
        for td in touch_dates:
            channel = weighted_channel_choice()
            campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
            touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, td))
            touchpoint_id_counter += 1

        first_convert = touch_dates[-1] + timedelta(hours=random.randint(1, 72))
        conversions.append((conversion_id_counter, user_id, first_convert,
                             round(random.uniform(REVENUE_MIN, REVENUE_MAX), 2)))
        conversion_id_counter += 1

        n_repeats = random.randint(1, 3)
        last_date = first_convert
        for _ in range(n_repeats):
            gap = timedelta(days=random.randint(20, 60))
            if last_date + gap >= END_DATE:
                break
            # light re-engagement touch before repeat purchase
            re_touch_date = last_date + gap - timedelta(days=random.randint(0, 2))
            channel = weighted_channel_choice()
            campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
            touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, re_touch_date))
            touchpoint_id_counter += 1

            repeat_convert_date = last_date + gap
            conversions.append((conversion_id_counter, user_id, repeat_convert_date,
                                 round(random.uniform(REVENUE_MIN, REVENUE_MAX), 2)))
            conversion_id_counter += 1
            last_date = repeat_convert_date

    elif scenario == "long_gap":
        # touches spread over 30-90 days, tests time-decay weighting meaningfully
        n_touches = random.randint(2, 5)
        window_days = random.randint(30, 90)
        journey_start = random_date(START_DATE, END_DATE - timedelta(days=window_days + 3))
        touch_dates = sorted(
            journey_start + timedelta(days=random.uniform(0, window_days))
            for _ in range(n_touches)
        )
        for td in touch_dates:
            channel = weighted_channel_choice()
            campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
            touchpoints.append((touchpoint_id_counter, user_id, channel, campaign, td))
            touchpoint_id_counter += 1

        convert_date = touch_dates[-1] + timedelta(hours=random.randint(1, 48))
        conversions.append((conversion_id_counter, user_id, convert_date,
                             round(random.uniform(REVENUE_MIN, REVENUE_MAX), 2)))
        conversion_id_counter += 1

# Sprinkle in some same-day rapid journeys (scenario 6) by injecting extra
# same-day touches onto ~5% of existing multi-touch users, tests tie-breaking
extra_rapid_rows = []
existing_user_ids = list({t[1] for t in touchpoints})
rapid_sample = random.sample(existing_user_ids, k=int(len(existing_user_ids) * 0.05))
for uid in rapid_sample:
    base_date = random_date(START_DATE, END_DATE - timedelta(days=1))
    for _ in range(random.randint(2, 4)):
        channel = weighted_channel_choice()
        campaign = random.choice(CAMPAIGNS_BY_CHANNEL[channel])
        same_day_time = base_date + timedelta(minutes=random.randint(0, 600))
        extra_rapid_rows.append((touchpoint_id_counter, uid, channel, campaign, same_day_time))
        touchpoint_id_counter += 1
touchpoints.extend(extra_rapid_rows)

# ---------------------------------------------------------------------------
# Daily cost data (channel x day grain, with weekday/weekend and seasonal variation)
# ---------------------------------------------------------------------------

costs = []
current_date = START_DATE
while current_date <= END_DATE:
    is_weekend = current_date.weekday() >= 5
    # simple seasonal bump: higher spend Nov-Dec (campaign period), matches
    # touchpoint volume roughly so ROAS calculations later look plausible
    seasonal_multiplier = 1.4 if current_date.month in (11, 12) else 1.0
    weekend_multiplier = 0.7 if is_weekend else 1.0

    for channel in CHANNELS:
        base = CHANNEL_BASE_DAILY_SPEND[channel]
        if base == 0:
            spend = 0.0
        else:
            noise = random.uniform(0.85, 1.15)
            spend = round(base * seasonal_multiplier * weekend_multiplier * noise, 2)
        costs.append((current_date.date(), channel, spend))

    current_date += timedelta(days=1)

# ---------------------------------------------------------------------------
# Write CSVs
# ---------------------------------------------------------------------------

touchpoints.sort(key=lambda r: r[4])
with open(OUTPUT_DIR / "raw_touchpoints.csv", "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["touchpoint_id", "user_id", "channel", "campaign", "touchpoint_timestamp"])
    for row in touchpoints:
        writer.writerow([row[0], row[1], row[2], row[3], row[4].strftime("%Y-%m-%d %H:%M:%S")])

conversions.sort(key=lambda r: r[2])
with open(OUTPUT_DIR / "raw_conversions.csv", "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["conversion_id", "user_id", "conversion_timestamp", "revenue"])
    for row in conversions:
        writer.writerow([row[0], row[1], row[2].strftime("%Y-%m-%d %H:%M:%S"), row[3]])

with open(OUTPUT_DIR / "raw_costs.csv", "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["cost_date", "channel", "spend"])
    for row in costs:
        writer.writerow([row[0].strftime("%Y-%m-%d"), row[1], row[2]])

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

n_converting_users = len({c[1] for c in conversions})
n_repeat_users = len({c[1] for c in conversions}) - len({
    uid for uid in {c[1] for c in conversions}
    if sum(1 for c in conversions if c[1] == uid) == 1
})

print("Synthetic data generation complete.")
print(f"  Users simulated:        {N_USERS}")
print(f"  Touchpoints generated:  {len(touchpoints)}")
print(f"  Conversions generated:  {len(conversions)}")
print(f"  Converting users:       {n_converting_users}")
print(f"  Non-converting users:   {N_USERS - n_converting_users}")
print(f"  Cost rows (channel x day): {len(costs)}")
print(f"  Files written to:       {OUTPUT_DIR.resolve()}")
print("    - raw_touchpoints.csv")
print("    - raw_conversions.csv")
print("    - raw_costs.csv")
