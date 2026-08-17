# HANDOFF — Resume State for a Fresh Claude / New Session

> **Purpose:** This file lets a new Claude (or a new account/session with no memory of prior chats) pick up this project exactly where it was left off. It captures operational state, locked decisions, gotchas, and the immediate next step — the things NOT already in the committed docs.

## First, read these (in order)
1. **[INSTRUCTIONS.md](INSTRUCTIONS.md)** — the *learning loop* this project runs on: coach HINTS the next step from PROJECT.md → user BUILDS it (solo or paired) → coach QUIZZES on the build + the certification topics it covers → COMMIT via PR → repeat. **Follow this loop. Do NOT hand the user finished code unless asked** — they build it as the study exercise.
2. **[PROJECT.md](PROJECT.md)** — the phased roadmap (Phases 0–7) + the certification traceability matrix.
3. **[TUTORIAL.md](TUTORIAL.md)** — help/cheat-sheets/troubleshooting for when stuck.
4. **[dbt_Study_Guide_AI_Knowledge_Base.md](dbt_Study_Guide_AI_Knowledge_Base.md)** — official exam topics + 10 sample questions (source of truth for quiz topics).

## What to tell the fresh Claude when resuming
> "Read HANDOFF.md and INSTRUCTIONS.md. We're building this dbt-certification project via the learning loop. Check git + the dbt project to confirm where I am, then hint me on the next step from PROJECT.md, let me build it, and quiz me after."

---

## Who / Why
- User: **Pablo Jaramillo**. Goal: pass the **dbt Analytics Engineering certification** by building this end-to-end project himself, and **publish the repo** so others can learn the same way.
- Learn-by-building: the user writes the code; the coach hints, reviews, debugs, and quizzes.

## Environment & config (operational — verify before use)
- **OS/shell:** Windows 11, PowerShell 5.1. Watch encoding: write files other tools read as **UTF-8 no BOM** (`[System.IO.File]::WriteAllText`), not `Out-File`/`Set-Content -Encoding utf8`.
- **`setx PYTHONUTF8 1`** is set — required so dbt doesn't hit cp1252 `UnicodeDecodeError` on non-ASCII in files/package docs. If a fresh machine, set it again.
- **Project venv (use THIS, not the global CLAUDE.md work venv):** `C:\EndToEnd_AnalyticsProject_Olist_Dataset\.venv` — Python 3.13, dbt-core 1.11.x, dbt-bigquery. Run dbt as `.venv\Scripts\dbt.exe` or activate `.\.venv\Scripts\Activate.ps1`.
- **Run dbt from** `C:\EndToEnd_AnalyticsProject_Olist_Dataset\dbt` with `$env:DBT_PROFILES_DIR = "profiles"` (committed at `dbt/profiles/profiles.yml`, oauth/ADC, no secrets).
- **GCP project:** `olist-analytics-501518` | region `us-central1` | BQ location `US`.
  - Datasets: `raw_olist` (sources), `dbt_pjaramillo` (dev target), `analytics*` (prod, via `generate_schema_name` override — not built yet).
  - Bucket: `olist-analytics-501518-datalake` (raw zone + dbt-state; 60-day lifecycle on `raw/`).
  - Service accounts: `sa-ingestion` (built), `sa-dbt-runner`/`sa-dashboard`/`sa-github-actions` (NOT created yet — make each when its phase needs it).
- **GitHub:** repo pushed; `main` protected (require PR, 0 approvals — solo repo; you can't approve your own PR). Work on feature branches → PR → `gh pr merge --squash --delete-branch` → `git checkout main && git pull` → new branch.

## Locked decisions
- Ingestion is a **Cloud Run job** (Docker + Artifact Registry + Scheduler), NOT a Cloud Run function. Code in `ingestion/` (`main.py`, `Dockerfile`, `deploy.ps1`). Raw is **full-rewrite** each run (small static dataset).
- Incrementality is **simulated in dbt**, not ingestion: `stg_olist__orders` has an `as_of_date` visibility cursor (`var('as_of_date','2018-12-31')` default = full history; override in dev to simulate arrivals). See TUTORIAL section 4.12. User chose the var-cursor approach over date-shifting.
- Staging carries **business columns only** (`_loaded_at` dropped from staging; freshness reads it from the raw source).
- dbt Core on GCP is the main build; free **dbt platform** account is Phase 7 (supplementary — exam is Core-centric, v1.11).
- CI/CD: GitHub Actions, Slim CI (`state:modified+ --defer`), Workload Identity Federation.

## Progress tracker
- **Phase 0 (Foundations):** ✅ done (GCP, budget, bucket+lifecycle, sa-ingestion + IAM, Kaggle secret, GitHub + branch protection, venv/dbt).
- **Phase 1 (Ingestion job):** ✅ done, merged. Runs Kaggle→GCS→BigQuery, scheduled weekly.
- **Phase 2 (Raw layer):** ✅ done. All 9 `raw_olist` tables loaded (`_loaded_at` added; `allow_quoted_newlines` for reviews).
- **Phase 3 (dbt) — IN PROGRESS:**
  - 3.1 scaffold + profiles ✅
  - 3.2 sources + 9 staging models ✅, model tests in `_olist__models.yml` ✅, source tests (reviews `unique` set to `severity: warn` — fails by design, documents raw dup review_ids) ✅. `dbt build --select staging` is **green**.
  - **3.3 (NEXT): intermediate + marts modeling.** `models/intermediate/` and `models/marts/` are empty.
  - 3.4–3.10 not started (seeds, snapshots, macros, full tests, docs/exposures, governance, debugging drills, state).
- Phases 4–7 (prod Cloud Run job, CI/CD, Dash, dbt platform): not started.

## Gotchas already learned (don't rediscover the hard way)
- **cp1252 / UnicodeDecodeError** → `setx PYTHONUTF8 1`; also avoid pasting rich text (`—`, `←`, `§`, smart quotes) into `.sql`/`.yml`.
- **BOM** breaks `bq`/dbt file reads → write UTF-8 no BOM via `WriteAllText`.
- **BigQuery dataset ACLs** use legacy role names (WRITER=dataEditor); service accounts go under `userByEmail`. `bq add-iam-policy-binding` needs allowlisting on this project → use read-modify-write of the access list (see `GCP_setup`).
- **dbt models have NO trailing semicolon** (dbt wraps them in DDL).
- **`dbt build` skips downstream models on a failed test**; `severity: warn` reports without blocking. `dbt run` ignores tests.
- Scheduler→Cloud Run job uses `--oauth-service-account-email` (OAuth), not OIDC.

## Immediate next step (Phase 3.3)
Building the intermediate layer, target grain **one row per order** for both:
- `int_orders__joined` — orders (spine) + customers (1:1 on customer_id) + **aggregated** order_items (group to order grain first to avoid fan-out).
- `int_payments__pivoted` — payments pivoted to one row per order (`dbt_utils.pivot` + `get_column_values`).

Method taught: confirm each input's grain (`count(*)` vs `count(distinct key)`), measure fan-out, check coverage (orders vs orders_with_items/payments/reviews) to pick inner vs left joins. **Golden rule:** aggregate/pivot the many-side to target grain BEFORE joining. Then build marts (`fct_orders` incremental w/ the as_of_date cursor, `dim_customers` on `customer_unique_id`, etc.).

## Open reminders / quiz notes
- User did the staging-tests quiz (~6.5/8). Weak spot to reinforce: the **four test CATEGORIES** = generic / singular / custom-generic / unit (he listed the 4 built-in *generics* instead).
- Before publishing the repo: consider a `README.md` pointing newcomers to INSTRUCTIONS.md; this HANDOFF.md is transient working state (can be deleted or kept as a living status doc).
