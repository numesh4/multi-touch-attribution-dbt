# multi-touch-attribution-dbt

A dbt project for multi-touch attribution (first-touch, last-touch, linear, and time-decay) using synthetic marketing data. Designed as a portfolio/project scaffold: generate or load sample data, run dbt models, and compare attribution methodologies alongside an incrementality check.

---

## Quick links
- Project root: `.`
- Sources YAML: [models/staging/_staging__sources.yml](models/staging/_staging__sources.yml)
- Data generator: [build_source_data.py](build_source_data.py) (the older `generate_synthetic_data.py` is deprecated, kept as `generate_synthetic_data(deprecated).py`)
- Docs: [docs/docs_data_methodology.md](docs/docs_data_methodology.md)

---

## One-line summary
Build and compare multiple multi-touch attribution methods with synthetic data and dbt. Use this repo as a sandbox for attribution experiments.

---

## Current project stage
- Staging models `stg_customers_unification`, `stg_touchpoints`, and `stg_conversions` are built and validated.
- The intermediate journey model `int_user_journeys` (stitching touchpoints to conversions) is built.
- The next phase is cost-data staging (`stg_costs`) and the attribution marts.

---

## Getting started (super quick)
1. Ensure you have Python 3.10+ and dbt installed (DuckDB adapter recommended for local dev).

2. Load the synthetic source data directly into DuckDB:

   ```bash
   python build_source_data.py
   # requires dev.duckdb to already exist (run `dbt debug` at least once first)
   # writes into dev.duckdb across seven raw_* schemas
   ```

   (An older CSV-seed generator, `generate_synthetic_data(deprecated).py`, is kept for reference but no longer matches the current source schemas — use `build_source_data.py`.)

3. Run dbt (example flow):

   ```bash
   dbt deps
   dbt seed      # only if using CSV seeds
   dbt run
   dbt test
   dbt docs generate
   dbt docs serve
   ```

   If you want to validate only the currently built models:

   ```bash
   dbt run --select stg_customers_unification stg_touchpoints stg_conversions int_user_journeys
   dbt test --select stg_customers_unification stg_touchpoints stg_conversions int_user_journeys
   ```

Tips:
- If you use the DuckDB route, ensure your dbt profile points to `dev.duckdb` or your adapter of choice.
- `build_source_data.py` creates multiple realistic raw schemas (raw_ga4, raw_meta_pixel, raw_callrail, raw_helpdesk, raw_shopify, raw_google_ads, raw_meta_ads).

---

## Project layout (short)
- dbt_project.yml — project config
- models/
  - staging/ — source YAMLs and staging SQL models for raw source normalization (stg_*)
  - intermediate/ — journey stitching (int_*)
  - marts/ — attribution marts (fct_*)
- macros/ — reusable SQL macros (add time-decay macro here)
- seeds/ — (optional) CSV seeds produced by generator
- docs/ — methodology and ERD

See [dbt_project.yml](dbt_project.yml) for materialization defaults.

---

## Recommended next steps (prioritized)
1. Add staging normalization for cost data:
   - `models/staging/stg_costs.sql` to normalize Google Ads / Meta Ads spend and convert units to standard currency.
2. Implement attribution marts (`models/marts/attribution/`): first-touch, last-touch, linear, time-decay, and a summary comparison mart.
3. Add `macros/time_decay_weight.sql` to centralize decay logic and make models DRY.
4. (Optional) Build `int_user_sessions` if session-level (rather than journey-level) grouping is needed.
5. (Optional) Add CI: GitHub Actions to run `dbt seed/run/test` on PRs and protect `main` branch.

---

## Design notes
- Synthetic data is intentionally realistic: inconsistent column names across sources, cost in micros for Google Ads, and separate raw schemas mirroring production extract pipelines.
- Identity resolution is simplified for this project — real systems require more complex stitching and backfills (documented in `docs/docs_data_methodology.md`).

---

## Contributing
Contributions welcome. Suggested flow:
1. Fork
2. Create a feature branch (e.g. `feat/staging-models`)
3. Implement models/tests/docs
4. Open a PR with a clear description and example run commands

---

## License
MIT — see LICENSE in the repo root.

---

Authorship
Project authored by Nikash Umesh. See `build_source_data.py` (current) and `generate_synthetic_data(deprecated).py` (earlier version) for generation details and authorship notes.
