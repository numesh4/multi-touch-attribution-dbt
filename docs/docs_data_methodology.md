# Data Methodology and Realism Notes

Current project stage: staging models (`stg_touchpoints`, `stg_conversions`, `stg_customers_unification`, `stg_costs`), the intermediate journey model (`int_user_journeys`), the attribution layer (`int_attribution_credit` computing per-touchpoint credit for all four methods, rolled up into `fct_attribution_summary` and exposed at full grain in `fct_attribution_detail`), and the incrementality holdout (`int_holdout_conversion_rates`, `fct_incrementality_vs_attribution`) are built. See the Incrementality holdout design section below. The next phase is polishing this into the project's case-study artifact.

This document explains the design decisions behind the synthetic dataset used in this project, why it was built the way it was, and the known limitations of the approach. It's intended to sit alongside the technical models as a plain-language reference, the kind of document anyone could read without needing to open any SQL.

---

## Source systems

Data is landed as eight raw tables across seven schemas in DuckDB, each standing in for a distinct real-world source system, rather than one combined flat file. This mirrors how marketing data actually arrives in a warehouse: via separate extract-and-load pipelines per source, not as one clean, pre-joined export. Data is loaded directly into DuckDB by `build_source_data.py`, bypassing `dbt seed` entirely, the same way an EL tool (Fivetran, Airbyte, or a custom API extract script) would land it, not dbt.

| Schema | Table | Stands in for | Grain |
|---|---|---|---|
| `raw_ga4` | `ga4events` | GA4 / Segment web analytics export | Event-grain, one row per touchpoint interaction (`paid_search`, `email`, `organic` touches) |
| `raw_meta_pixel` | `meta_pixel_events` | Meta Pixel / Conversions API export | Event-grain, one row per `paid_social` touchpoint, tracked independently of GA4 |
| `raw_callrail` | `calls` | CallRail-style call tracking export | Event-grain, one row per inbound phone touchpoint |
| `raw_helpdesk` | `inbound_helpdesk_emails` | Zendesk/Freshdesk-style support inbox export | Event-grain, one row per inbound email touchpoint |
| `raw_shopify` | `shopify_orders` | Shopify / CRM orders export | Order-grain, one row per purchase (repeat purchasers produce multiple rows) |
| `raw_shopify` | `customers` | Shopify / CRM customer export | Customer-grain, one row per customer, with B2B/B2C segment, phone, and email |
| `raw_google_ads` | `google_campaign_costs` | Google Ads API cost export | Daily-grain, one row per channel per day |
| `raw_meta_ads` | `meta_ad_insights` | Meta Ads API cost export | Daily-grain, one row per campaign group per day, with impressions and clicks |

Each source uses its own realistic column naming (`ga_user_id` vs. `fb_external_id` vs. `caller_phone_number` vs. `from_email`), which is deliberate. It forces the staging layer to do genuine normalization work, reconciling schemas that were never designed to agree with each other, rather than a simple passthrough. Two of the four touchpoint sources, `calls` and `inbound_helpdesk_emails`, don't carry a customer ID at all; they're matched by phone number or email address instead, a deliberately realistic identity-resolution challenge (see below).

---

## Customer segmentation: B2B vs. B2C

Every synthetic customer is randomly assigned a segment, weighted 85% `b2c` / 15% `b2b`, and that segment shapes the rest of their journey rather than just sitting as a label:

- **Channel mix** differs by segment. B2C customers are weighted toward `paid_search` and `paid_social`; B2B customers are weighted toward `phone` and `email_inbound` (sales calls, inquiries) and away from `paid_social`. A pure scenario based decision, can be amended as needed to swap behaviour. 
- **Journey scenario mix** differs by segment. B2B customers are far less likely to be single-touch converters (10% vs. 35% for B2C) and far more likely to have a long-gap, multi-week sales cycle (20% vs. 2% for B2C). See the journey scenarios table below.
- **Revenue** differs by segment: B2C orders range $35–$420, B2B orders range $800–$6,000, reflecting a self-serve checkout vs. a sales-assisted purchase.

This gives the attribution models a genuine reason to disagree by segment, not just by channel, useful for segment-cut attribution and LTV analysis, not just a single blended view.

---

## Channels

Six channels are generated, landing across four different touchpoint source tables:

**paid_search** — Advertising bought on search engines, shown when a user searches a relevant keyword. Pay-per-click, high intent since the user is actively searching. Lands in `raw_ga4.ga4events`.

**paid_social** — Advertising bought on social platforms, shown in-feed or in-story regardless of active search intent. Generally lower intent per impression than paid search, but effective for awareness and re-engagement. Tracked independently of GA4 via Meta's own pixel, lands in `raw_meta_pixel.meta_pixel_events`.

**email** — Owned-channel messaging sent directly to users who've already opted in. No media cost to reach them, reflected in the cost data by its much lower spend relative to the paid channels. Lands in `raw_ga4.ga4events`.

**organic** — Unpaid traffic: unpaid search results (SEO), direct visits, content marketing, and referral links. No media spend, deliberately reflected as $0 in the cost data, which makes organic a useful benchmark in ROAS comparisons since it can't be measured against spend the way paid channels can. Lands in `raw_ga4.ga4events`.

**phone** — Inbound calls to a call-tracking number, driven by click-to-call ads or direct inquiries. Lands in `raw_callrail.calls`, matched to a customer by phone number rather than a customer ID, skews heavily toward B2B.

**email_inbound** — Inbound support/sales emails initiated by the customer, as opposed to `email`, which is outbound marketing. Lands in `raw_helpdesk.inbound_helpdesk_emails`, matched to a customer by email address rather than a customer ID.

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

**phone**
- `inbound_sales_line` — a call to the general sales line, unprompted by a specific ad.
- `support_callback` — a call following up on an existing support interaction.
- `click_to_call_ad` — a call placed directly from a click-to-call ad unit.

**email_inbound**
- `product_inquiry` — a pre-sale question about a product.
- `support_request` — a post-sale support question.
- `sales_question` — a pre-sale question routed toward a sales conversation, common for B2B.

---

## Journey scenarios

Five distinct journey types, plus a same-day rapid-touch overlay, were generated deliberately, so the attribution models have genuine cases to disagree on, rather than a dataset where every journey looks the same. Scenario weights differ by customer segment: B2B skews toward multi-touch, long sales cycles and away from quick single-touch conversions.

| Scenario | Weight (B2C / B2B) | What it produces | Why it matters |
|---|---|---|---|
| Single-touch | 35% / 10% | One touch, converts within 48 hours | First-touch and last-touch attribution will agree here, a useful baseline case |
| Multi-touch | 35% / 35% | 3-8 touches over 3-21 days, then converts | The core case where linear and time-decay attribution diverge from first/last-touch |
| Non-converting | 20% / 20% | 1-4 touches, no conversion at all | Needed for a realistic funnel shape, and for the incrementality holdout test |
| Repeat purchaser | 8% / 15% | Initial multi-touch journey and conversion, then 1-3 repeat purchases (20-60 day gaps) with a lighter re-engagement touch before each | Provides the data needed for LTV-based channel attribution, not just first-order value |
| Long-gap journey | 2% / 20% | 2-5 touches spread over 30-90 days, then converts | Gives the time-decay model a meaningful case to weight touches differently by recency, and is the dominant shape of a B2B sales cycle |
| Same-day rapid touches | ~5% overlay, web channels only | 2-4 touches within hours of each other, layered onto existing users | Tests how the models handle tie-breaking when touchpoint order is ambiguous at a coarse time grain |

---

## Design choices made for realism

**Multi-source architecture, not a single flat table.** See the Source Systems section above.

**Inconsistent column naming across sources, by design.** Forces genuine staging-layer normalization rather than a rename-only passthrough.

**Two touchpoint sources with no customer ID at all.** `raw_callrail.calls` and `raw_helpdesk.inbound_helpdesk_emails` are matched to a customer by phone number or email address, not a shared key, forcing the staging layer to do real identity resolution rather than a simple join (see below).

**Cost data reported in micros.** Google Ads' API reports spend in micros (millionths of a currency unit), a real quirk of that platform's data format. The staging model has to correctly convert units, a small but realistic detail a generic dataset wouldn't include.

**B2B/B2C segmentation that shapes journeys, not just a label.** See the Customer Segmentation section above.

**Five distinct journey scenarios**, rather than uniform "some touches then a conversion" journeys, as detailed above.

**Seasonality and weekday/weekend variation in cost data.** Daily spend includes a November-December seasonal uplift and lower weekend spend, rather than flat daily costs, giving the forecasting module genuine seasonal signal to detect rather than a straight line.

---

## Identity resolution: modeled, with deliberate limitations

Earlier versions of this project assumed identity resolution had already happened cleanly upstream. That's no longer true: `stg_customers_unification` now performs real cross-source identity resolution, and `stg_touchpoints` and `stg_conversions` both resolve against it.

Each of the four touchpoint sources is matched to `raw_shopify.customers` by whatever identifier it actually carries:

- `raw_ga4.ga4events` and `raw_meta_pixel.meta_pixel_events` match on customer ID (`ga_user_id` / `fb_external_id`) directly against `customer_id`.
- `raw_callrail.calls` matches on a digit-normalized `caller_phone_number` against a digit-normalized `phone_number`.
- `raw_helpdesk.inbound_helpdesk_emails` matches on a lowercased, trimmed `from_email` against a lowercased, trimmed `email`.

Where no match is found, the touchpoint still gets a synthetic profile (`source_system|source_id`) so it isn't silently dropped, it's just not linked to a known customer or order. `match_method` on every resolved row (`customer_id_match`, `phone_match`, `email_match`, `unknown`) makes that distinction auditable downstream rather than hidden.

This is real identity resolution, but still a deliberate simplification of a production system in a few ways worth naming explicitly:

- **Matching is exact-string, not fuzzy or probabilistic.** A typo'd email or a phone number with an extra digit produces an `unknown` match rather than a partial-confidence match, the way a real identity graph (or a tool like Segment's ID resolution) would attempt.
- **No cross-identifier stitching.** If the same real person shows up with a matched email on one visit and an unmatched phone number on another, this model does not infer they're the same person unless one of those identifiers matches `raw_shopify.customers` directly. A production identity graph would stitch across co-occurring identifiers over time.
- **No backfill of historical unmatched touches once a match happens later.** If a touchpoint precedes the customer being identifiable at all (the real-world GA4 anonymous-cookie-until-login problem), it stays `unknown` rather than being retroactively linked.

If a meaningful share of touchpoints resolve to `unknown` in a real deployment, that gap needs to be quantified and disclosed alongside the attribution results, not hidden by the model.

---

## Incrementality holdout design

`build_source_data.py` randomly assigns every synthetic customer to `holdout_group`: `treatment` (85%) or `control` (15%), seeded for reproducibility. Control customers never receive `paid_search` or `paid_social` touchpoints — they can still convert via `organic`, `email`, `phone`, or `email_inbound`. The assignment is surfaced on `raw_shopify.customers` and carried through `stg_customers_unification.holdout_group`.

`int_holdout_conversion_rates` rolls this up to one row per group (conversion rate, revenue per customer). `fct_incrementality_vs_attribution` compares two numbers for paid channels:

- **Holdout-implied incremental value** — `(treatment_conversion_rate - control_conversion_rate) * treatment_customers`, and the equivalent for revenue. This is what the randomized split implies paid exposure actually caused.
- **Last-touch attributed value** — what `fct_attribution_summary` credits to `paid_search` + `paid_social` under last-touch attribution.

The gap between the two (`conversions_gap`, `revenue_gap`, and their `_pct` forms) is the project's central incrementality finding: attribution methods have no way to know what would have happened without the touchpoint, so they tend to over-credit channels for conversions that a randomized holdout suggests would have happened anyway.

**Limitations worth naming explicitly:**

- **One holdout split for the whole build period**, not a rolling or repeated experiment. A real incrementality program re-runs holdouts periodically, since channel effectiveness drifts over time.
- **All-or-nothing suppression.** Control customers get zero paid exposure rather than a reduced dose, which is a cleaner signal than most real holdout tests can achieve (ad platforms rarely allow a true 100% suppression at the individual level) but is less realistic than a partial-suppression design.
- **No interaction effects modeled.** Suppressing paid exposure doesn't change a control customer's organic/email/phone behavior in this simulation, whereas in reality, removing paid touches can shift some of that demand into other channels (or lose it entirely) — the two are treated as fully independent here.
- **The generator doesn't encode a causal effect of paid exposure on conversion, and this matters for how to read the output.** `assign_scenario()` (whether a customer converts, and how) is chosen independently of `holdout_group` — `holdout_group` only changes which channels a customer's touchpoints can land in, not whether they convert. So `treatment_conversion_rate` and `control_conversion_rate` come out essentially equal (a small gap, within sampling noise — not a real effect), and `holdout_implied_incremental_conversions`/`_revenue` will always be close to zero by construction, regardless of how much paid spend is simulated. **The finding this project demonstrates is not "the holdout measured a specific real-world lift."** It's that last-touch attribution still credits paid channels for a large share of conversions/revenue (thousands of conversions, several million in revenue) purely because paid touchpoints happen to co-occur in journeys that were going to convert anyway under any channel mix — exactly the failure mode incrementality testing exists to catch, just demonstrated here by an (expected, near-zero) holdout baseline rather than a moderate real-world lift. State this plainly in the case study rather than implying the synthetic data models a specific causal lift magnitude.

---

## Note on multi-touch attribution and revenue reconciliation

Worth stating explicitly for anyone reviewing the revenue-attribution work in this project (see Module 3): multi-touch attributed revenue summed across channels will not reconcile exactly to total revenue. Linear and time-decay models split fractional credit across multiple touchpoints, which can overcount when summed by channel, while first-touch and last-touch models under-attribute channels that only played a supporting role in a journey. This is a known, expected property of multi-touch attribution, not a data quality issue, and is documented here so it isn't presented as a discrepancy to be fixed.
