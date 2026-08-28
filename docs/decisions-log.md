# Decisions Log & Changelog

Record of the key decisions made during the build (and why), plus a running changelog of what shipped when. Referenced from the README and from `docs/docs_data_methodology.md`, which covers the dataset design in depth - this file is the shorter "what changed and why" companion.

---

## Key decisions

**DuckDB over Snowflake as the primary local dev target.**
The project originally targeted Snowflake. Switched early to DuckDB for zero setup cost and no trial-account expiry risk — nothing to provision, nothing that stops working after a free-tier window closes. Snowflake or Databricks can still be added later as a second target (see Module 5 of the training plan) once the model layer is stable enough that a portability check is worth doing once rather than after every schema change.

**Outbound email folded into `raw_ga4`, not a separate `raw_email_platform` schema.**
Early planning called for a standalone email-platform source. In the actual build, outbound marketing email (`email` channel) is tracked as an event type inside `raw_ga4.ga4events` alongside `paid_search` and `organic`, rather than its own raw schema. Inbound email (`email_inbound`) still gets its own source, `raw_helpdesk.inbound_helpdesk_emails`, since it's a genuinely different system (a support inbox, not an analytics event stream). Net result: 7 raw schemas / 8 raw tables, not 8 schemas.

**`stg_customers_unification` instead of `stg_customers`.**
Named to reflect what the model actually does — it's not a passthrough rename of `raw_shopify.customers`, it's where cross-source identity resolution happens (matching `raw_callrail.calls` and `raw_helpdesk.inbound_helpdesk_emails` back to a customer by phone/email, since neither carries a customer ID). The more specific name makes that job visible from the model list alone.

**No separate `raw_orders`/`stg_orders` for Module 3 (revenue attribution).**
Module 3 of the training plan originally assumed a dedicated orders table would need to be built. By the time Module 3 is reached, `raw_shopify.shopify_orders` and `stg_conversions` already carry `total_price` per order — Module 3's revenue work joins directly against the existing conversions staging model instead of standing up a parallel orders pipeline.

**No `dbt seed` for fact/transactional data.**
All synthetic source data (touchpoints, conversions, customers, costs) is loaded directly into DuckDB by `build_source_data.py` as separate raw schemas, not via CSV seeds. `dbt seed` is for small, static, hand-maintained reference data; loading directly into raw schemas mirrors how a real EL tool (Fivetran, Airbyte) would land data before dbt ever runs, which is the more realistic pattern to practice.

**Identity resolution is exact-match, not fuzzy/probabilistic.**
`stg_customers_unification` matches on exact digit-normalized phone numbers and exact lowercased/trimmed emails. A typo'd identifier resolves to `unknown` rather than a partial-confidence match. Deliberate simplification — full probabilistic identity resolution is out of scope for this project, but the limitation is tracked and surfaced via a `match_method` column rather than hidden.

**Incrementality holdout is a single 85/15 treatment/control split with all-or-nothing paid suppression.**
Control customers get zero `paid_search`/`paid_social` touchpoints rather than a reduced dose. Simpler to simulate and gives a cleaner signal than most real holdout tests can achieve, but is less realistic than partial suppression and doesn't model demand shifting to other channels when paid exposure is removed. Documented as a limitation rather than hidden — see `docs/docs_data_methodology.md`.

**`stg_customers_unification`'s dedup fixed to backfill via window function, not by changing the tie-break (2026-08-29).**
Adding `holdout_group` surfaced a real, pre-existing bug: the model's final `row_number()` dedup only ever kept `customer_type`/`holdout_group` from the `raw_shopify.customers` branch, and its tie-break (`is_known_customer desc, source_timestamp asc`) let a touchpoint-source row (with those fields null) win for roughly half of all known customers, since Shopify's `first_seen_date` is a random date unrelated to touchpoint timing. Confirmed 57% of known-customer rows had NULL `customer_type`/`holdout_group` before the fix. The first fix attempt (always preferring the Shopify branch in the tie-break) backfired: `stg_touchpoints.sql` looks up specific `(source_system, source_id)` rows from this model's output, so forcing Shopify to always win meant GA4/Meta-Pixel-tagged rows never survived dedup, and `paid_search`/`paid_social`/`organic`/`email` touchpoints stopped resolving to a known customer entirely. Fixed correctly by backfilling `customer_type`/`holdout_group` via `max(...) over (partition by customer_profile_id)` before the dedup, leaving the original tie-break untouched.

**`int_holdout_conversion_rates` materialized as a table, same reasoning as `int_attribution_credit`.**
It reads through the same expensive identity-resolution chain (`int_user_journeys` → `stg_touchpoints`'s correlated subqueries → `stg_customers_unification`). As a view, each of `fct_incrementality_vs_attribution`'s tests re-ran that whole chain from scratch; observed per-test time climbing past 100s before materializing as a table dropped it back to milliseconds.

**Found and fixed a severe, pre-existing bug in `int_user_journeys.sql`'s `non_converting_journeys` CTE (2026-08-29): `NOT IN` against a subquery that could contain a NULL.**
`converted_profiles` (`select distinct resolved_customer_profile_id from converting_journeys`) picked up NULL for 4 converting touchpoints where identity resolution set `resolved_known_customer_id` but not `resolved_customer_profile_id`. Per standard SQL, `x NOT IN (set containing NULL)` evaluates to `UNKNOWN` — never `TRUE` — for any `x` not otherwise matched, so the `where t.resolved_customer_profile_id not in (select ... from converted_profiles)` filter silently excluded **every** non-converting touchpoint, project-wide, not just ones related to the 4 affected rows. First noticed because `fct_incrementality_vs_attribution` was showing an impossible 100% conversion rate for both treatment and control. Fixed by adding `where resolved_customer_profile_id is not null` to `converted_profiles`. After the fix, `int_user_journeys` has ~8,200 non-converting rows again (previously silently zero), and both holdout groups show a realistic ~79-80% conversion rate.

**Important interpretive limitation surfaced by the above fix**: with non-converting journeys restored, `fct_incrementality_vs_attribution` shows treatment and control converting at essentially the *same* rate (a small negative gap, within noise) — because `build_source_data.py`'s journey-scenario assignment (`assign_scenario`) is independent of `holdout_group`. The generator doesn't encode a causal effect of paid exposure on conversion probability; `holdout_group` only changes which channels a customer's touchpoints land in, not whether or how much they convert. So the holdout-implied incremental lift will always be close to zero by construction — the real finding is that last-touch attribution still credits paid channels for a large share of conversions/revenue purely because paid touchpoints co-occur in journeys that were going to convert regardless of channel mix. Worth stating plainly in the case study rather than implying the synthetic data demonstrates a specific real-world lift magnitude — see `docs/docs_data_methodology.md`.

**Found and fixed non-deterministic tie-breaking in `stg_customers_unification`'s dedup (2026-08-29): added `source_system` as a final `order by` key.**
While chasing the bug above, a *third* issue surfaced: `not_null_int_attribution_credit_resolved_customer_profile_id` (a pre-existing test) failed on one full `dbt build` with 8 NULL rows, immediately after passing cleanly on the previous build, with zero model changes in between. Root cause: `stg_customers_unification`'s final `row_number() over (partition by customer_profile_id order by is_known_customer desc, source_timestamp asc)` has no tiebreaker beyond those two columns, so when two branches tie on both (observed for a couple of `meta_pixel`-sourced customers), the winner is whatever the query engine happens to pick — and `stg_touchpoints.sql` resolves `resolved_known_customer_id` and `resolved_customer_profile_id` via two *separate* correlated subqueries against this model's output, so an unstable tie could resolve those two subqueries to different rows, leaving one of the two fields NULL. Fixed by adding `source_system asc` as a final tiebreaker — `(customer_profile_id, source_system)` is unique by construction (each branch's own `group by` guarantees at most one row per profile per source), so this always fully resolves the tie. Confirmed fixed with two consecutive clean full `dbt build` runs (105/105 both times, including the previously-flaky test) against the same static data.

**`dev_alt.duckdb` removed from the repo (2026-08-14).**
An untracked-in-plan DuckDB file had been committed to git and wasn't covered by `.gitignore`. It wasn't referenced anywhere in the README, the training plan, or `dbt_project.yml`'s target config — a stray local artifact, not a second environment the project actually uses. Removed from git tracking and added to `.gitignore` to prevent recommitting it. (Recoverable from git history at commit `7af0868` if it turns out to be needed.)

---

## Changelog

| Date | Change |
|---|---|
| 2026-07-13 | Initial commit |
| 2026-07-19 | dbt project structure set up with the DuckDB adapter |
| 2026-07-19 | B2B/B2C customer segmentation and Meta Ads cost source added |
| 2026-08-04 | Meta event sources and call-center (CallRail) data points added to `build_source_data.py` |
| 2026-08-04 | `stg_touchpoints` and `stg_customers_unification` built; docs updated |
| 2026-08-08 | Staging validation status and roadmap finalized in docs after a clean `dbt run`/`dbt test` |
| 2026-08-12 | Fixed journey touchpoint ordering scope and `journey_id` uniqueness test in `int_user_journeys` |
| 2026-08-12 | Added `is_repeat_purchase` flag to `stg_conversions` |
| 2026-08-12 | Synced methodology, ERD, and README with current source schema and model state |
| 2026-08-14 | Repo cleanup: removed stray `dev_alt.duckdb`, added MIT `LICENSE`, added this decisions log |
| 2026-08-16 | `stg_costs` and `fct_attribution_first_touch` built |
| 2026-08-17 | `fct_attribution_last_touch` built |
| 2026-08-17 | Fixed a `UNION ALL` column-order bug in `stg_customers_unification` and a wrong join key in `stg_touchpoints`' meta_pixel resolution — together these had zeroed out attribution for `paid_search`, `paid_social`, `organic`, and `email` |
| 2026-08-17 | `fct_attribution_linear` and `fct_attribution_time_decay` built |
| 2026-08-19 | Refactored the four `fct_attribution_*` method marts into `int_attribution_credit` (per-touchpoint credit for all four methods, one table, materialized since it's read by two marts) plus `fct_attribution_summary` (channel x method rollup) and `fct_attribution_detail` (full touchpoint/customer/journey grain). The four individual marts were deleted — each was a pure re-slice of `fct_attribution_summary` post-refactor, so they added no data, only narrative value. Also dropped `sample_seed` and `test_unification`, two orphaned tables in `dev.duckdb` with no corresponding dbt model. |
| 2026-08-29 | Added the incrementality holdout: `holdout_group` on `build_source_data.py`/`stg_customers_unification`, `int_holdout_conversion_rates`, and `fct_incrementality_vs_attribution`. Found and fixed a pre-existing `stg_customers_unification` dedup bug along the way (see Key decisions). |
| 2026-08-29 | Found and fixed a severe pre-existing bug in `int_user_journeys`'s `non_converting_journeys` CTE: a `NOT IN` filter against a subquery that could return NULL was silently dropping every non-converting journey project-wide (see Key decisions). |
| 2026-08-29 | Found and fixed non-deterministic tie-breaking in `stg_customers_unification`'s dedup, added a sanity test (`tests/assert_holdout_conversion_rates_are_realistic.sql`), and drafted `docs/case-study.md` (see Key decisions). |
