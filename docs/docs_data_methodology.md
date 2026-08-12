# Data Methodology and Realism Notes

Current project stage: staging and customer unification models are built and validated, and the next phase is intermediate journey modeling and attribution marts.

This document explains the design decisions behind the synthetic dataset used in this project, why it was built the way it was, and the known limitations of the approach. It's intended to sit alongside the technical models as a plain-language reference, the kind of document a stakeholder or interviewer could read without needing to open any SQL.

---

## Source systems

Data is landed as three separate raw schemas in DuckDB, each standing in for a distinct real-world source system, rather than one combined flat file. This mirrors how marketing data actually arrives in a warehouse: via separate extract-and-load pipelines per source, not as one clean, pre-joined export.

| Schema | Table | Stands in for | Grain |
|---|---|---|---|
| `raw_ga4` | `events` | GA4 / Segment web analytics export | Event-grain, one row per touchpoint interaction |
| `raw_shopify` | `orders` | Shopify / CRM orders export | Order-grain, one row per purchase (repeat purchasers produce multiple rows) |
| `raw_google_ads` | `campaign_costs` | Google Ads API cost export | Daily-grain, one row per channel per day |
| `raw_meta_ads` | `campaign_costs` | Meta Ads API cost export | Daily-grain, one row per channel per day |

Each source uses its own realistic column naming (`ga_user_id` vs. `customer_id`, `event_timestamp` vs. `created_at`), which is deliberate. It forces the staging layer to do genuine normalization work, reconciling schemas that were never designed to agree with each other, rather than a simple passthrough.

---

## Channels

**paid_search** — Advertising bought on search engines, shown when a user searches a relevant keyword. Pay-per-click, high intent since the user is actively searching.

**paid_social** — Advertising bought on social platforms, shown in-feed or in-story regardless of active search intent. Generally lower intent per impression than paid search, but effective for awareness and re-engagement.

**email** — Owned-channel messaging sent directly to users who've already opted in. No media cost to reach them, reflected in the cost data by its much lower spend relative to the paid channels.

**organic** — Unpaid traffic: unpaid search results (SEO), direct visits, content marketing, and referral links. No media spend, deliberately reflected as $0 in the cost data, which makes organic a useful benchmark in ROAS comparisons since it can't be measured against spend the way paid channels can.

---

## Campaigns, by channel

**paid_search**
- `brand_search` — bidding on the company's own brand name, typically cheap and high-converting since the user already knows the brand.
- `generic_search` — bidding on category or product keywords not tied to the brand, more competitive and typically more expensive per click.
- `competitor_search` — bidding on a competitor's brand name, intercepting their searchers.

**paid_social**
- `prospecting_ig` — Instagram ads targeting people who haven't interacted with the brand before, a cold-audience awareness play.
- `retargeting_fb` — Facebook ads shown to people who've already visited the site or shown interest, a warm-audience conversion play.
- `lookalike_tiktok` — TikTok ads targeting audiences that resemble existing customers, based on a lookalike audience model.

**email**
- `newsletter` — regular scheduled content sent to the full subscriber list, mixed intent.
- `abandoned_cart` — triggered email sent to someone who added items to a cart but didn't complete the purchase, high intent, reminder-style.
- `win_back` — triggered email sent to lapsed or inactive customers, trying to re-engage.

**organic**
- `blog` — traffic arriving via a blog or content page, usually from search or social shares.
- `direct` — traffic with no identifiable referring source, typically a typed URL or bookmark.
- `referral` — traffic arriving via a link from another website.

---

## Journey scenarios

Six distinct journey types were generated deliberately, so the attribution models have genuine cases to disagree on, rather than a dataset where every journey looks the same.

| Scenario | Weight | What it produces | Why it matters |
|---|---|---|---|
| Single-touch | 30% | One touch, converts within 48 hours | First-touch and last-touch attribution will agree here, a useful baseline case |
| Multi-touch | 35% | 2-6 touches over 3-21 days, then converts | The core case where linear and time-decay attribution diverge from first/last-touch |
| Non-converting | 20% | 1-4 touches, no conversion at all | Needed for a realistic funnel shape, and for the incrementality holdout test |
| Repeat purchaser | 10% | Initial multi-touch journey and conversion, then 1-3 repeat purchases with a lighter re-engagement touch before each | Provides the data needed for LTV-based channel attribution, not just first-order value |
| Long-gap journey | 5% | 2-5 touches spread over 30-90 days, then converts | Gives the time-decay model a meaningful case to weight touches differently by recency |
| Same-day rapid touches | ~5% overlay | 2-4 touches within hours of each other, layered onto existing users | Tests how the models handle tie-breaking when touchpoint order is ambiguous at a coarse time grain |

---

## Design choices made for realism

**Multi-source architecture, not a single flat table.** See the Source Systems section above.

**Inconsistent column naming across sources, by design.** Forces genuine staging-layer normalization rather than a rename-only passthrough.

**Cost data reported in micros.** Google Ads' API reports spend in micros (millionths of a currency unit), a real quirk of that platform's data format. The staging model has to correctly convert units, a small but realistic detail a generic dataset wouldn't include.

**Six distinct journey scenarios**, rather than uniform "some touches then a conversion" journeys, as detailed above.

**Seasonality and weekday/weekend variation in cost data.** Daily spend includes a November-December seasonal uplift and lower weekend spend, rather than flat daily costs, giving the forecasting module genuine seasonal signal to detect rather than a straight line.

---

## Known limitation: identity resolution is assumed, not modeled

The synthetic data uses a single, stable `user_id` shared across all three sources. In a real implementation, this is the hard part.

GA4 identifies visitors by an anonymous, cookie-based client ID, not a stable person-level identity. That client ID only resolves to a known customer once the user logs in or is otherwise identified, via GA4's User-ID feature, an email hash match, or a click-ID passed through the URL. Touchpoints occurring before that identification point are often unmatched to any known customer unless a separate identity-resolution process backfills them.

This project assumes identity resolution has already happened cleanly, which is a simplification. In a production setting, the completeness of attribution is bounded by the completeness of identity stitching. If a meaningful share of touchpoints can't be matched to a converting user, that gap needs to be quantified and disclosed alongside the attribution results, not hidden by the model.

---

## Note on multi-touch attribution and revenue reconciliation

Worth stating explicitly for anyone reviewing the revenue-attribution work in this project (see Module 3): multi-touch attributed revenue summed across channels will not reconcile exactly to total revenue. Linear and time-decay models split fractional credit across multiple touchpoints, which can overcount when summed by channel, while first-touch and last-touch models under-attribute channels that only played a supporting role in a journey. This is a known, expected property of multi-touch attribution, not a data quality issue, and is documented here so it isn't presented as a discrepancy to be fixed.
