# Case Study: Multi-Touch Attribution vs. Incrementality

## The problem

Marketing teams routinely use multi-touch attribution (first-touch, last-touch, linear, time-decay) to decide where to put spend. But every attribution method has the same structural blind spot: it can only describe *correlation* — which channels showed up in a converting journey — never *causation* — whether that channel actually caused the conversion, or whether the customer would have converted anyway. This project builds a synthetic but realistic marketing dataset, computes all four standard attribution methods, and then builds an incrementality holdout (a randomized treatment/control split) to measure the gap between what attribution *credits* and what a controlled experiment *implies actually happened*.

## Data model

Six channels (`paid_search`, `paid_social`, `email`, `organic`, `phone`, `email_inbound`) land across four independent raw source systems (GA4-style events, Meta Pixel, CallRail-style call tracking, a helpdesk inbox), plus Shopify-style orders/customers and Google/Meta Ads cost exports — eight raw tables in seven schemas, each with its own realistic column naming, mirroring how marketing data actually arrives in a warehouse via separate extract pipelines rather than one clean flat file. `stg_customers_unification` performs real cross-source identity resolution (customer ID, phone, or email match); `stg_touchpoints` and `stg_conversions` resolve against it; `int_user_journeys` stitches resolved touchpoints to orders into full customer journeys, both converting and non-converting. See `docs/docs_data_methodology.md` for the full design rationale.

30,000 synthetic customers, ~105K touchpoints, ~29,600 orders, six journey scenarios (single-touch, multi-touch, non-converting, repeat purchaser, long-gap, same-day rapid touches) weighted differently by B2B/B2C segment so the attribution methods have genuine cases to disagree on.

## Methodology

**Attribution.** `int_attribution_credit` computes per-touchpoint fractional credit for all four methods in one place (first-touch and last-touch: 0/1; linear: `1/total_touches`; time-decay: normalized exponential decay, 7-day half-life). `fct_attribution_summary` rolls this up by channel and method.

**Incrementality holdout.** At data-generation time, every customer is randomly assigned to `treatment` (85%) or `control` (15%). Control customers receive zero `paid_search`/`paid_social` touchpoints — they can still convert through organic, email, phone, or inbound email — while treatment customers see the full, unrestricted channel mix. `int_holdout_conversion_rates` computes conversion rate and revenue per customer for each group; `fct_incrementality_vs_attribution` compares the holdout-implied incremental effect against what last-touch attribution credits to `paid_search` + `paid_social`.

## Key finding

| | Value |
|---|---|
| Treatment conversion rate | 79.1% |
| Control conversion rate | 79.9% |
| Holdout-implied incremental conversions (paid channels) | ≈ 0 (slightly negative — within noise) |
| Last-touch attributed conversions (paid channels) | 7,238 |
| Last-touch attributed revenue (paid channels) | $4.4M |

Treatment and control customers convert at essentially the **same rate**. That's expected here — this synthetic dataset's conversion outcome is decided by journey-scenario assignment independently of channel exposure, so there's no simulated causal effect of paid marketing on conversion to detect (see the "Incrementality holdout design" limitations in `docs/docs_data_methodology.md` for why, and why that's a deliberate property of the data, not a bug to explain away).

What that makes visible is the actual lesson: **last-touch attribution still credits paid channels for 7,238 conversions and $4.4M in revenue**, purely because paid touchpoints happen to co-occur in journeys that were converting regardless of channel mix. Attribution has no way to distinguish "this channel caused the conversion" from "this channel was merely present" — a randomized holdout does, and here it shows the true incremental effect is indistinguishable from zero. That gap — correlation-based credit vs. a near-zero causal baseline — is exactly the failure mode incrementality testing exists to catch, and it's the reason mature marketing orgs pair attribution with periodic holdout tests rather than trusting attribution alone to size a media budget.

(This finding also depended on fixing two real, non-obvious bugs uncovered while building it: a `NOT IN` filter against a subquery that could contain `NULL` was silently dropping every non-converting journey project-wide, and a non-deterministic tie-break in identity resolution could flip a handful of results between otherwise-identical `dbt build` runs. Both are documented in `docs/decisions-log.md` — worth a mention in interviews as much as the finding itself, since catching them required not trusting a clean-looking `dbt test` run at face value.)

## What I'd do differently with real data

- **Repeat the holdout periodically, not once.** A single split over the whole build period can't detect that channel effectiveness drifts over time; a real program re-runs holdouts on a cadence.
- **Partial suppression, not all-or-nothing.** This project denies control customers 100% of paid exposure, which is cleaner to simulate than most real ad platforms can actually deliver (true individual-level suppression is rarely available) — a real holdout usually works with a reduced dose or geo-based splits instead.
- **Model interaction effects.** Here, suppressing paid exposure doesn't shift any demand into other channels. In reality, removing paid touches can move some of that volume into organic/email (or lose it entirely) — treating channels as fully independent understates how holdouts actually behave.
- **Stratify the random split.** The 85/15 assignment here isn't stratified by B2B/B2C or by expected value, so small imbalances between groups (e.g. revenue-per-customer differing even when conversion rate doesn't) are partly confounding rather than signal. A real test would stratify or check balance post-hoc.
- **Fuzzy/probabilistic identity resolution.** This project's identity matching is exact-string only (see `docs/docs_data_methodology.md`); real identity graphs stitch across co-occurring identifiers and tolerate typos, which would change both the attribution and the holdout population sizes.
