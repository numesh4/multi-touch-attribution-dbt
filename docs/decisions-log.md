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
