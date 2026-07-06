# TUTORIAL.md — Helper Guide for the Olist End-to-End Analytics Project

> **How to use this document:** Don't read it linearly. When you're stuck in a phase of [PROJECT.md](PROJECT.md), jump to the matching section here. §8 (Troubleshooting by Symptom) is organized by error message/behavior. §4 holds the dbt cheat sheets you'll reuse until exam day.

**Contents**

1. [Environment & GCP Setup](#1-environment--gcp-setup)
2. [Ingestion (Cloud Run Function → GCS)](#2-ingestion-cloud-run-function--gcs)
3. [BigQuery Raw Layer](#3-bigquery-raw-layer)
4. [dbt — Concepts, Cheat Sheets, and How-Tos](#4-dbt--concepts-cheat-sheets-and-how-tos)
5. [Docker & Cloud Run](#5-docker--cloud-run)
6. [CI/CD (GitHub Actions)](#6-cicd-github-actions)
7. [Dash Dashboard](#7-dash-dashboard)
8. [Troubleshooting by Symptom](#8-troubleshooting-by-symptom)
9. [dbt Platform (dbt Cloud) Study Notes](#9-dbt-platform-dbt-cloud-study-notes)
10. [Exam-Prep Appendix](#10-exam-prep-appendix)

---

## 1. Environment & GCP Setup

### 1.1 gcloud CLI (Windows)

Install from https://cloud.google.com/sdk/docs/install, then in PowerShell:

```powershell
gcloud init                                  # pick account, create/select project
gcloud auth application-default login        # ADC — what dbt & Python clients use locally
gcloud config set project olist-analytics-<suffix>
gcloud config list                           # verify
```

> **ADC vs `gcloud auth login`:** `gcloud auth login` authenticates the *CLI*. `application-default login` writes credentials that *libraries* (dbt-bigquery oauth, google-cloud-storage, google-cloud-bigquery) pick up automatically. You need both.

### 1.2 Project, billing, budget

```powershell
gcloud projects create olist-analytics-<suffix> --name="Olist Analytics"
gcloud billing accounts list
gcloud billing projects link olist-analytics-<suffix> --billing-account=XXXXXX-XXXXXX-XXXXXX
```

Budget alerts: Console → Billing → Budgets & alerts → Create budget (e.g. $10/mo, thresholds 25/50/75/100%). Do this **before** anything else.

### 1.3 Enable APIs (one command)

```powershell
gcloud services enable run.googleapis.com storage.googleapis.com bigquery.googleapis.com `
  artifactregistry.googleapis.com cloudscheduler.googleapis.com cloudbuild.googleapis.com `
  secretmanager.googleapis.com iamcredentials.googleapis.com
```

### 1.4 Service accounts & roles

```powershell
gcloud iam service-accounts create sa-ingestion --display-name "Olist ingestion"
gcloud iam service-accounts create sa-dbt-runner --display-name "dbt prod runner"
gcloud iam service-accounts create sa-dashboard --display-name "Dash dashboard"
gcloud iam service-accounts create sa-github-actions --display-name "GitHub Actions"
```

Minimal role map (grant with `gcloud projects add-iam-policy-binding` or per-resource where possible):

| SA | Roles |
|---|---|
| `sa-ingestion` | `roles/storage.objectAdmin` (on the bucket), `roles/bigquery.jobUser`, `roles/bigquery.dataEditor` (on `raw_olist`), `roles/secretmanager.secretAccessor` |
| `sa-dbt-runner` | `roles/bigquery.jobUser`, `roles/bigquery.dataEditor` (on `analytics*`, `raw_olist` read), `roles/storage.objectAdmin` (on `dbt-state/` prefix) |
| `sa-dashboard` | `roles/bigquery.jobUser` + dataset-level viewer on marts **only** (dbt `grants` will manage this) |
| `sa-github-actions` | `roles/run.developer`, `roles/artifactregistry.writer`, `roles/bigquery.jobUser`, `roles/bigquery.dataEditor` (CI datasets), `roles/storage.objectViewer` (dbt-state), `roles/iam.serviceAccountUser` |

> **Tip:** grant BigQuery roles at the *dataset* level (`bq update --dataset` with an access entry, or Console → dataset → Sharing) instead of project level. Least privilege is itself a learning objective here.

### 1.5 Python venv + dbt (Windows)

```powershell
py -3.13 -m venv .venv     # 3.12+ all work; 3.13 is what's installed on this machine
.\.venv\Scripts\Activate.ps1
pip install dbt-bigquery google-cloud-storage google-cloud-bigquery functions-framework kaggle dash gunicorn
dbt --version
```

> If PowerShell blocks activation: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

### 1.6 Kaggle API token

Kaggle now uses individual API tokens (the old `kaggle.json` download is under "Legacy API Credentials"). Get one at kaggle.com → Settings → API → **Generate New Token** and copy the token string.

**Locally**, either authenticate via the browser OAuth flow (`kaggle auth login`) or set the env var for the session:

```powershell
$env:KAGGLE_API_TOKEN = "<your-token>"
```

**For the cloud**, store the token string in Secret Manager (write it to a temp file without a trailing newline — a stray `\n` in the secret breaks auth invisibly):

```powershell
Set-Content -Path token.txt -Value "<your-token>" -NoNewline -Encoding ascii
gcloud secrets create kaggle-credentials --data-file=token.txt
Remove-Item token.txt
```

Keep the `kaggle` Python package up to date in `ingestion/requirements.txt` — `KAGGLE_API_TOKEN` support is recent; old package versions only know `KAGGLE_USERNAME`/`KAGGLE_KEY` (which still work, but only with legacy keys).

### 1.7 GCS lifecycle rule (cost guardrail)

```powershell
# lifecycle.json: delete raw objects older than 60 days
gsutil lifecycle set lifecycle.json gs://<project>-datalake
```

---

## 2. Ingestion (Cloud Run Function → GCS)

### 2.1 Skeleton `main.py`

```python
import functions_framework
from google.cloud import storage, secretmanager
import os, tempfile, datetime

def _load_kaggle_token():
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{os.environ['GCP_PROJECT']}/secrets/kaggle-credentials/versions/latest"
    token = client.access_secret_version(name=name).payload.data.decode().strip()
    os.environ["KAGGLE_API_TOKEN"] = token

@functions_framework.http
def ingest(request):
    _load_kaggle_token()
    import kaggle  # import AFTER the token env var is set — kaggle authenticates at import time
    today = datetime.date.today().isoformat()
    with tempfile.TemporaryDirectory() as tmp:
        kaggle.api.dataset_download_files("olistbr/brazilian-ecommerce", path=tmp, unzip=True)
        bucket = storage.Client().bucket(os.environ["BUCKET"])
        summary = {}
        for f in os.listdir(tmp):
            if not f.endswith(".csv"):
                continue
            table = f.replace(".csv", "")
            blob = bucket.blob(f"raw/olist/{table}/ingestion_date={today}/{f}")
            blob.upload_from_filename(os.path.join(tmp, f))
            summary[table] = "uploaded"
    return summary, 200
```

Idempotency comes free: same-day re-runs overwrite the same blob path.

### 2.2 Run locally

```powershell
$env:GCP_PROJECT="olist-analytics-<suffix>"; $env:BUCKET="<project>-datalake"
functions-framework --target=ingest --debug
# in another terminal:
curl http://localhost:8080
```

### 2.3 Deploy + schedule

```powershell
gcloud functions deploy ingest-olist --gen2 --runtime=python312 --region=us-central1 `
  --source=ingestion --entry-point=ingest --trigger-http --no-allow-unauthenticated `
  --service-account=sa-ingestion@<project>.iam.gserviceaccount.com `
  --set-env-vars GCP_PROJECT=<project>,BUCKET=<project>-datalake `
  --memory=1Gi --timeout=540

gcloud scheduler jobs create http ingest-olist-weekly --schedule="0 6 * * 1" `
  --uri=<FUNCTION_URL> --http-method=POST --location=us-central1 `
  --oidc-service-account-email=sa-ingestion@<project>.iam.gserviceaccount.com
```

Test an authenticated call yourself:

```powershell
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" <FUNCTION_URL>
```

---

## 3. BigQuery Raw Layer

### 3.1 Create datasets

```powershell
bq mk --location=US --dataset --label env:raw --label owner:pjaramillo <project>:raw_olist
bq mk --location=US --dataset <project>:analytics
bq mk --location=US --dataset <project>:dbt_pjaramillo
```

> **Location is forever.** Every dataset (and the GCS bucket, ideally) must share one location. Cross-location queries/loads fail with `Not found: Dataset` or explicit location errors.

### 3.2 Load job pattern (Python)

```python
from google.cloud import bigquery
import datetime

client = bigquery.Client()
today = datetime.date.today().isoformat()

job_config = bigquery.LoadJobConfig(
    source_format=bigquery.SourceFormat.CSV,
    skip_leading_rows=1,
    autodetect=True,                      # pin explicit schemas once stable
    write_disposition="WRITE_TRUNCATE",
)
uri = f"gs://<bucket>/raw/olist/olist_orders_dataset/ingestion_date={today}/*.csv"
client.load_table_from_uri(uri, "raw_olist.olist_orders_dataset", job_config=job_config).result()

# add the freshness column dbt will use
client.query("""
  ALTER TABLE raw_olist.olist_orders_dataset ADD COLUMN IF NOT EXISTS _loaded_at TIMESTAMP;
  UPDATE raw_olist.olist_orders_dataset SET _loaded_at = CURRENT_TIMESTAMP() WHERE _loaded_at IS NULL;
""").result()
```

(Cleaner alternative: load into a temp table and `CREATE OR REPLACE TABLE ... AS SELECT *, CURRENT_TIMESTAMP() AS _loaded_at`.)

### 3.3 Quick sanity checks

```powershell
bq query --use_legacy_sql=false "SELECT COUNT(*) FROM raw_olist.olist_orders_dataset"   # ≈ 99441
bq show --schema raw_olist.olist_orders_dataset
```

---

## 4. dbt — Concepts, Cheat Sheets, and How-Tos

### 4.1 profiles.yml for BigQuery (dev oauth + prod service account)

```yaml
olist:
  target: dev
  outputs:
    dev:
      type: bigquery
      method: oauth                 # uses your ADC from §1.1
      project: olist-analytics-<suffix>
      dataset: dbt_pjaramillo
      location: US
      threads: 4
      maximum_bytes_billed: 10737418240   # 10 GB cap per query — cost guardrail
    prod:
      type: bigquery
      method: oauth                 # in Cloud Run, ADC = the job's service account
      project: olist-analytics-<suffix>
      dataset: analytics
      location: US
      threads: 8
      priority: interactive
      maximum_bytes_billed: 10737418240   # 10 GB cap per query — cost guardrail
```

Point dbt at a committed profiles dir with `--profiles-dir ./profiles` or `DBT_PROFILES_DIR`. No secrets needed when using oauth/ADC everywhere.

### 4.2 Command cheat sheet

| Command | What it does | Notes |
|---|---|---|
| `dbt debug` | Validates profile, connection, git | First thing to run on any setup issue |
| `dbt deps` | Installs packages from `packages.yml` | Re-run after editing packages.yml |
| `dbt seed` | Loads `seeds/*.csv` as tables | `--full-refresh` to recreate |
| `dbt run` | Builds models only | |
| `dbt test` | Runs tests only | |
| `dbt build` | run + test + seed + snapshot, DAG-ordered | **The prod command.** Tests gate downstream models |
| `dbt snapshot` | Runs snapshots | Also included in `build` |
| `dbt compile` | Renders Jinja → SQL in `target/compiled/` | Debugging weapon #1 |
| `dbt ls --select ...` | Dry-run of node selection | Verify selectors before running |
| `dbt docs generate` / `dbt docs serve` | Build/serve docs site & DAG | |
| `dbt source freshness` | Checks source freshness SLAs | Writes `sources.json` |
| `dbt retry` | Re-runs from the failure point of the last run | Needs `target/run_results.json` |
| `dbt clone` | Copies relations from another env's state (zero-copy where supported) | vs `--defer`: clone *materializes*, defer *redirects refs* |
| `dbt show --select model` | Preview a model's results inline | |
| `dbt run/build --empty` | Dry run: refs/sources limited to **zero rows** | Validates schema & logic near-free; tests then run on empty tables and *pass* — see §10.2 |
| `dbt run --sample=...` | Sample mode: time-bounded slice of event-time data | Dev cost-saver; needs `event_time` configured |

`dbt build` vs `dbt run` is a classic exam distinction: **build** runs models *and their tests* in DAG order, so a failing upstream test **skips** downstream models; **run** ignores tests entirely.

### 4.3 Materialization decision guide

| Materialization | What it creates | Use when | Olist example |
|---|---|---|---|
| `view` (default) | View | Cheap logic, always-fresh, low query volume | All staging models |
| `table` | Table, full rebuild each run | Heavily queried, moderate size, logic fits a rebuild | dims, marts |
| `incremental` | Table, only processes new/changed rows | Large fact tables, append/merge patterns | `fct_orders` |
| `ephemeral` | Nothing — inlined as a CTE into consumers | Light reusable logic you don't want in the warehouse | an `int_` model |
| `materialized_view` | Warehouse-managed MV | Warehouse auto-refresh semantics | optional stretch |

**Incremental skeleton (BigQuery merge):**

```sql
{{ config(
    materialized='incremental',
    unique_key='order_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    partition_by={'field': 'order_date', 'data_type': 'date'},
    cluster_by=['customer_state']
) }}

select ...
from {{ ref('stg_olist__orders') }}
{% if is_incremental() %}
  where order_purchase_timestamp > (select max(order_purchase_timestamp) from {{ this }})
{% endif %}
```

Remember: first run (or `--full-refresh`) builds the whole table; `is_incremental()` is true only when the table already exists, it's not a full-refresh run, and materialization is incremental.

**Incremental strategy selection (the exam tests *choosing*, not just configuring):**

| Strategy | How it works | Choose when |
|---|---|---|
| `append` | Inserts new rows, never updates | Immutable event logs; duplicates impossible (or acceptable); cheapest |
| `merge` | MERGE on `unique_key` | Rows can arrive late or be updated in place; classic default with a unique key |
| `insert_overwrite` | Replaces whole partitions | Large partitioned tables; you reprocess by partition — cheaper than merge at scale |
| `microbatch` | dbt splits the run into independent event-time batches | Large event-time datasets; you want per-batch retry/backfill without hand-written `is_incremental()` logic |

**Microbatch skeleton:**

```sql
{{ config(
    materialized='incremental',
    incremental_strategy='microbatch',
    event_time='order_purchase_date',
    batch_size='month',
    lookback=1,
    begin='2016-09-01'
) }}
select ... from {{ ref('stg_olist__order_items') }}
```

Microbatch rules: no `is_incremental()` filter — dbt auto-filters each `ref`/`source` by the batch window, **but only if the upstream model/source also has `event_time` configured**. Each batch runs (and can fail/retry) independently: `dbt retry` re-runs only failed batches, and `--event-time-start` / `--event-time-end` backfill a specific range.

**Snapshot skeletons:**

```sql
{% snapshot orders_status_check %}
{{ config(target_schema='analytics_snapshots', unique_key='order_id',
          strategy='check', check_cols=['order_status']) }}
select order_id, order_status from {{ ref('stg_olist__orders') }}
{% endsnapshot %}
```

`timestamp` strategy needs a reliable `updated_at`; `check` strategy compares listed columns. Snapshots add `dbt_valid_from`/`dbt_valid_to` (`dbt_valid_to IS NULL` = current row).

### 4.4 Jinja / macro crash course

```sql
{{ ... }}   -- expression: prints result into SQL
{% ... %}   -- statement: control flow (if, for, set, macro)
{# ... #}   -- comment: not rendered
```

Key objects: `ref()`, `source()`, `this` (current relation), `target` (`target.name`, `target.dataset`), `var('name', default)` (from `--vars` / dbt_project.yml), `env_var('NAME')` (from OS env — use for secrets), `run_query()` (executes SQL at compile time — guard with `{% if execute %}`).

```sql
-- macros/limit_data_in_dev.sql
{% macro limit_data_in_dev(column, days=90) %}
  {% if target.name == 'dev' %}
    where {{ column }} >= date_sub(current_date(), interval {{ days }} day)
  {% endif %}
{% endmacro %}
```

**Custom schemas (the exam favorite):** by default dbt builds into `<target_dataset>_<custom_schema>`. Overriding `generate_schema_name` lets prod use the custom schema name directly (`analytics_marts`) while dev keeps everything in your sandbox dataset:

```sql
-- macros/generate_schema_name.sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if target.name == 'prod' and custom_schema_name is not none -%}
        {{ target.schema }}_{{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema }}
    {%- endif -%}
{%- endmacro %}
```

### 4.5 Config precedence (memorize)

```
1. {{ config(...) }} in the model file        ← wins
2. dbt_project.yml, most specific folder path
3. dbt_project.yml, project-level default
4. dbt built-in default (view)
```

YAML `config:` under a model's schema entry sits between 1 and 2. Same idea for tags/materializations/etc.

**Flags & global configs (exam subtopic: "managing dbt behavior with flags"):** runtime behavior lives in the `flags:` block of `dbt_project.yml` — e.g. `fail_fast`, `send_anonymous_usage_stats`, `warn_error`, and **behavior-change flags** (how dbt phases in breaking changes; they default to legacy behavior until you opt in). Their own precedence order:

```
CLI flag (--fail-fast)  >  env var (DBT_FAIL_FAST)  >  flags: in dbt_project.yml  >  dbt default
```

Know both hierarchies and don't mix them up: §4.5's model-config precedence governs *what gets built*; flag precedence governs *how dbt behaves while building*.

### 4.6 Test types table

| Type | Lives in | Example |
|---|---|---|
| Generic (built-in) | model/source YAML | `unique`, `not_null`, `accepted_values`, `relationships` |
| Singular | `tests/*.sql` — a SELECT returning *failing rows* | `assert_delivery_after_purchase.sql` |
| Custom generic | `{% test name(model, column_name) %}` in `tests/generic/` or `macros/` | `is_recent` |
| Package | YAML, from installed package | `dbt_expectations.expect_column_values_to_be_between` |
| Unit test (≥1.8) | `unit_tests:` YAML block with mock `given`/`expect` rows | validate mart logic pre-build |

Useful configs: `severity: warn|error`, `error_if`/`warn_if` thresholds, `where`, `store_failures: true` (writes failing rows to an audit schema), test at source vs model level.

**Custom generic test skeleton:**

```sql
-- tests/generic/test_is_recent.sql
{% test is_recent(model, column_name, days=30) %}
select *
from {{ model }}
where {{ column_name }} < timestamp_sub(current_timestamp(), interval {{ days }} day)
{% endtest %}
```

### 4.7 Node selection cheat sheet

| Syntax | Selects |
|---|---|
| `--select my_model` | just that node |
| `--select my_model+` | node + all descendants |
| `--select +my_model` | node + all ancestors |
| `--select +my_model+` | full lineage both ways |
| `--select @my_model` | node, descendants, and *their* ancestors (CI classic) |
| `--select my_model+2` | limit graph depth to 2 |
| `--select tag:marts` | by tag |
| `--select path:models/staging` or `staging.*` | by path/package |
| `--select source:olist+` | everything downstream of a source |
| `--select config.materialized:incremental` | by config |
| `--select result:error+ --state ...` | failed nodes from a previous run + descendants |
| `--select source_status:fresher+ --state ...` | sources fresher than last recorded + descendants |
| `--select state:modified+ --state ...` | changed vs the state manifest + descendants |
| `a b` (space) | union |
| `a,b` (comma) | intersection |
| `--exclude x` | subtract |

YAML selector example:

```yaml
# selectors.yml
selectors:
  - name: nightly
    definition:
      union:
        - method: tag
          value: marts
        - method: source
          value: olist
          children: true
```

### 4.8 State, defer, clone — the mental model

- **Artifacts:** every invocation writes `target/manifest.json` (full project graph — the "state"), `run_results.json` (per-node status/timing), `catalog.json` (docs), `sources.json` (freshness).
- **`--state <dir>`** points dbt at a *previous* manifest so it can diff: `state:modified` = nodes whose SQL/config/upstream macros changed.
- **`--defer`** = for selected nodes' *unselected parents*, resolve `ref()` to the other environment's relation instead of expecting it in yours. This is how Slim CI builds 3 models without rebuilding 40 parents.
- **`dbt clone`** = actually copy (zero-copy clone in BigQuery) relations from the state env into yours. Defer *points at* prod; clone *copies* prod.
- **`dbt retry`** = rerun the previous invocation from its point of failure using `run_results.json`.

Local drill (from PROJECT 3.10):

```powershell
dbt build --target prod --profiles-dir profiles
Copy-Item target/manifest.json state/
# edit a staging model...
dbt ls  --select state:modified+ --state state
dbt build --select state:modified+ --defer --state state --target dev
```

### 4.9 Contracts, versions, groups & access (governance)

```yaml
models:
  - name: fct_orders
    access: public
    group: finance
    latest_version: 1
    config:
      contract: {enforced: true}
    columns:
      - name: order_id
        data_type: string
        constraints: [{type: not_null}]
    versions:
      - v: 1
      - v: 2
        columns:
          - include: all
            exclude: [old_column]
groups:
  - name: finance
    owner: {name: Pablo Jaramillo, email: pablo.jaramillo@quantumlends.com}
```

- **Contract:** build fails if the model's actual columns/types drift from the YAML spec. Protects downstream consumers.
- **Constraints** (per-column YAML, enforced by the *platform*, not by dbt): `not_null`, `primary_key`, `foreign_key`, `unique`, `check`. Two rules the exam loves:
  1. With an enforced contract, **every column needs an explicit `data_type`** — a constraint on a column without one throws a *parsing* error before any SQL runs (sample question 8).
  2. Enforcement is platform-dependent: BigQuery enforces `not_null`, keeps `primary_key`/`foreign_key` as unenforced metadata, and doesn't support `check`. Contracts validate shape at build time; constraints delegate integrity to the warehouse.
- **Access:** `private` (own group only) / `protected` (own project, default) / `public` (anyone, incl. other projects in dbt Mesh).
- **Versions:** `ref('fct_orders')` → latest_version; `ref('fct_orders', v=1)` → pinned. `deprecation_date` emits warnings.

### 4.10 Docs

```yaml
# using a doc block
columns:
  - name: order_status
    description: '{{ doc("order_status") }}'
```

```markdown
{% docs order_status %}
One of: created, approved, invoiced, processing, shipped, delivered, canceled, unavailable.
{% enddocs %}
```

`persist_docs: {relation: true, columns: true}` pushes descriptions into BigQuery metadata. `dbt docs generate` builds `catalog.json`; `dbt docs serve` hosts locally.

### 4.11 Exposures

```yaml
exposures:
  - name: olist_dashboard
    type: dashboard
    maturity: high
    url: https://<cloud-run-url>
    owner: {name: Pablo Jaramillo, email: pablo.jaramillo@quantumlends.com}
    depends_on:
      - ref('mart_revenue_daily')
      - ref('mart_delivery_performance')
      - ref('mart_review_scores')
```

`dbt ls --select +exposure:olist_dashboard` = "what feeds my dashboard"; run it before changing anything upstream.

---

## 5. Docker & Cloud Run

### 5.1 dbt runner Dockerfile

```dockerfile
FROM python:3.12-slim
RUN pip install --no-cache-dir dbt-bigquery google-cloud-storage
WORKDIR /app
COPY dbt/ ./dbt/
COPY dbt_runner/entrypoint.sh .
WORKDIR /app/dbt
RUN dbt deps --profiles-dir profiles
ENTRYPOINT ["bash", "/app/entrypoint.sh"]
```

```bash
# entrypoint.sh
set -e
dbt source freshness --target prod --profiles-dir profiles
dbt build --target prod --profiles-dir profiles
gsutil cp target/manifest.json target/run_results.json target/sources.json \
  gs://${BUCKET}/dbt-state/prod/    # or use a small python upload script
```

Inside Cloud Run, ADC is the job's service account automatically — `method: oauth` in profiles.yml just works. **No key files.**

### 5.2 Build, push, create the job

```powershell
gcloud artifacts repositories create analytics --repository-format=docker --location=us-central1
gcloud auth configure-docker us-central1-docker.pkg.dev

docker build -f dbt_runner/Dockerfile -t us-central1-docker.pkg.dev/<project>/analytics/dbt-runner:latest .
docker push us-central1-docker.pkg.dev/<project>/analytics/dbt-runner:latest

gcloud run jobs create dbt-build `
  --image=us-central1-docker.pkg.dev/<project>/analytics/dbt-runner:latest `
  --region=us-central1 --service-account=sa-dbt-runner@<project>.iam.gserviceaccount.com `
  --set-env-vars BUCKET=<project>-datalake --memory=2Gi --task-timeout=1800

gcloud run jobs execute dbt-build --region=us-central1 --wait
```

Nightly schedule (Scheduler → Cloud Run job REST endpoint):

```powershell
gcloud scheduler jobs create http dbt-build-nightly --schedule="0 8 * * *" --location=us-central1 `
  --uri="https://run.googleapis.com/v2/projects/<project>/locations/us-central1/jobs/dbt-build:run" `
  --http-method=POST --oauth-service-account-email=sa-dbt-runner@<project>.iam.gserviceaccount.com
```

---

## 6. CI/CD (GitHub Actions)

### 6.1 Workload Identity Federation (keyless auth)

```powershell
gcloud iam workload-identity-pools create github --location=global
gcloud iam workload-identity-pools providers create-oidc github-provider `
  --location=global --workload-identity-pool=github `
  --issuer-uri="https://token.actions.githubusercontent.com" `
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" `
  --attribute-condition="assertion.repository=='<gh-user>/<repo>'"

gcloud iam service-accounts add-iam-policy-binding sa-github-actions@<project>.iam.gserviceaccount.com `
  --role=roles/iam.workloadIdentityUser `
  --member="principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/attribute.repository/<gh-user>/<repo>"
```

### 6.2 Slim CI workflow

```yaml
# .github/workflows/ci_dbt.yml
name: dbt Slim CI
on:
  pull_request:
    paths: ["dbt/**"]
permissions: {contents: read, id-token: write}
jobs:
  slim-ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/providers/github-provider
          service_account: sa-github-actions@<project>.iam.gserviceaccount.com
      - uses: actions/setup-python@v5
        with: {python-version: "3.12"}
      - run: pip install dbt-bigquery
      - run: gcloud storage cp gs://<bucket>/dbt-state/prod/manifest.json state/
        working-directory: dbt
      - name: Build modified models, defer the rest to prod
        working-directory: dbt
        env:
          DBT_CI_DATASET: dbt_ci_pr_${{ github.event.number }}
        run: |
          dbt deps --profiles-dir profiles
          dbt build --select state:modified+ --defer --state state \
            --target ci --profiles-dir profiles
```

(Add a `ci` target in profiles.yml whose `dataset` reads `env_var('DBT_CI_DATASET')`. Add a cleanup workflow on `pull_request: closed` that runs `bq rm -r -f -d <project>:dbt_ci_pr_<n>`.)

### 6.3 Deploy workflow sketch

```yaml
# .github/workflows/deploy_dbt_job.yml
on:
  push: {branches: [main], paths: ["dbt/**", "dbt_runner/**"]}
# steps: auth (WIF) → docker build/push → gcloud run jobs update dbt-build --image=...
```

Same shape for the dashboard (`gcloud run deploy` instead of `jobs update`).

---

## 7. Dash Dashboard

### 7.1 Structure

```
dashboard/
├── app.py            # Dash(use_pages=True), server = app.server
├── pages/
│   ├── revenue.py
│   ├── delivery.py
│   └── customers.py
├── data.py           # BigQuery client + cached query helpers
├── requirements.txt  # dash, gunicorn, google-cloud-bigquery, pandas, flask-caching
└── Dockerfile
```

```python
# data.py — cache aggressively; marts refresh nightly at most
from google.cloud import bigquery
from flask_caching import Cache
client = bigquery.Client()
cache = Cache(config={"CACHE_TYPE": "SimpleCache", "CACHE_DEFAULT_TIMEOUT": 3600})

@cache.memoize()
def revenue_daily():
    return client.query("select * from analytics_marts.mart_revenue_daily").to_dataframe()
```

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD exec gunicorn --bind 0.0.0.0:$PORT --workers 2 app:server
```

> Cloud Run injects `$PORT` (8080). The #1 deploy failure is not binding to it. Note `app:server` — gunicorn serves the **Flask** server inside Dash, not the Dash object.

### 7.2 Deploy

```powershell
gcloud run deploy olist-dashboard --source dashboard --region=us-central1 `
  --service-account=sa-dashboard@<project>.iam.gserviceaccount.com `
  --allow-unauthenticated --memory=1Gi --min-instances=0
```

Then paste the service URL into the dbt exposure (PROJECT 3.7 / 6.3).

---

## 8. Troubleshooting by Symptom

### 8.1 GCP / auth

| Symptom | Likely cause → fix |
|---|---|
| `403 Permission denied` on any API | Missing role on the *acting identity*. Find who's acting (`gcloud auth list`, or the service's SA), grant the specific role. Wait ~1 min for IAM propagation |
| `Could not automatically determine credentials` | ADC not set locally → `gcloud auth application-default login` |
| `404 Not found: Dataset` but it exists | **Location mismatch** (US vs EU vs region) or wrong project. Check `location:` in profiles.yml vs `bq show` |
| Scheduler → Cloud Run returns 403 | Scheduler's OIDC/OAuth SA lacks `run.invoker` (service) / `run.developer`+`iam.serviceAccountUser` (job REST call) |
| Quota / billing errors | Billing not linked, or budget alert ≠ hard cap (alerts don't stop spend — check what's running) |

### 8.2 dbt — compilation errors (before SQL runs)

| Symptom | Likely cause → fix |
|---|---|
| `Compilation Error ... 'ref' ... was not found` / `Model 'x' depends on a node named 'y' which was not found` | Typo in `ref()`/`source()` name, or the file isn't in `model-paths`. `dbt ls` to see what dbt actually sees |
| `Compilation Error in ... duplicate resource` | Two files/models with the same name anywhere in the project |
| YAML parse errors (`mapping values are not allowed`) | Indentation/`:` problems in a schema file — the error names file and line; validate spacing (2 spaces, no tabs) |
| Parsing error: invalid configuration for a column with a constraint | Contract enforced but the column has no `data_type`, or the constraint type isn't supported on BigQuery (`check`) → define `data_type` for every column; check platform support (§4.9) |
| `dict object has no attribute ...` in Jinja | Wrong variable/attribute inside `{{ }}` — often a macro arg mismatch or `var()` without default |
| Macro not found | Package not installed (`dbt deps`) or macro file not under `macro-paths` |

### 8.3 dbt — database errors (SQL reached BigQuery)

Workflow: read the message → open the model's file in `target/compiled/` (or `target/run/` for the wrapped DDL) → run that SQL in the BigQuery console → fix the *source* file, never the compiled file.

| Symptom | Likely cause → fix |
|---|---|
| `Unrecognized name: <column>` | Column renamed upstream or typo — check the staging model's aliases |
| `Table not found` in **dev** but model exists | Upstream never built in your dev dataset → `dbt build --select +that_model`, or use `--defer` |
| Works in dev, fails in prod (or vice versa) | Environment drift: custom schema override, permissions of prod SA, or hardcoded dataset (should be `ref`/`source`!) — the classic "dbt issue disguised as SQL" |
| Incremental model missing new columns | `on_schema_change` default is `ignore` → set `append_new_columns` or `--full-refresh` once |
| Incremental weird duplicates | No/wrong `unique_key`, or strategy `insert_overwrite` without matching partition filter |
| Snapshot error re: existing table | Schema of snapshot changed — snapshots are stateful; don't casually edit their select list |

### 8.4 dbt — tests & runs

| Symptom | Likely cause → fix |
|---|---|
| Test fails but you expected pass | `store_failures: true`, then query the audit table to see offending rows |
| `relationships` test fails on Olist customers | Grain confusion: `customer_id` is per-order; `customer_unique_id` is the person. Point the test/join at the right key (intended lesson!) |
| Duplicate `review_id` failures | Real Olist data quirk — dedupe in staging (`qualify row_number() over (...) = 1`) and document it |
| Downstream models `SKIP` in `dbt build` | An upstream test failed — that's by design; fix or demote to `severity: warn` deliberately |
| `state:modified` selects "everything" | Comparing against a manifest from a different dbt version/target or after project-wide config change — regenerate state from the same environment |
| `--defer` still hits dev tables | The parent WAS selected (so it builds in your target), or the deferred relation doesn't exist in prod yet |

### 8.5 Docker / Cloud Run

| Symptom | Likely cause → fix |
|---|---|
| Service deploy: `container failed to start and listen on PORT` | Bind gunicorn/app to `0.0.0.0:$PORT`; don't hardcode 8050 (Dash default) |
| Job dies mid-`dbt build`, exit 137 | Out of memory → raise `--memory`, lower `threads` |
| `permission denied` pulling/pushing image | `gcloud auth configure-docker <region>-docker.pkg.dev` not run, or missing `artifactregistry.writer` |
| Job succeeds locally, fails in Cloud Run with auth errors | Locally you're *you*; in Cloud Run it's the job's SA — grant the SA the missing role |
| Kaggle import crashes at cold start | `import kaggle` before `KAGGLE_API_TOKEN` is set — import inside the handler after loading the secret |
| Kaggle auth fails with a valid token | Trailing newline stored in the secret (recreate with `-NoNewline`), or an old `kaggle` package version that predates `KAGGLE_API_TOKEN` — upgrade it |

### 8.6 GitHub Actions

| Symptom | Likely cause → fix |
|---|---|
| `Unable to acquire impersonated credentials` / WIF errors | `permissions: id-token: write` missing; provider attribute condition doesn't match `owner/repo`; wrong PROJECT_NUMBER in the provider path |
| CI can't find `manifest.json` | Prod job hasn't uploaded artifacts yet (run Phase 4 once first), or wrong GCS path |
| CI builds the whole project | See `state:modified` row in §8.4 |

---

## 9. dbt Platform (dbt Cloud) Study Notes

Core-vs-platform map — the platform column is what the exam may reference:

| Concern | dbt Core (this project) | dbt platform |
|---|---|---|
| Where you develop | Local venv + editor | Cloud IDE or dbt Cloud CLI |
| Connection config | `profiles.yml` targets | **Environments** + per-developer credentials (no profiles.yml) |
| Prod runs | Cloud Run job + Scheduler | **Jobs** (scheduled, with run history UI) |
| CI | GitHub Actions + `--defer --state` | **CI jobs** — deferral to prod environment is a checkbox |
| State/artifacts | You upload manifest.json to GCS | Stored automatically per job run |
| Docs | `dbt docs serve` locally | Hosted docs + **Explorer** (lineage, model health) |
| Freshness | `dbt source freshness` in the entrypoint | Job setting / Explorer surfacing |
| Access to warehouse | ADC / service accounts you manage | Connections configured in the platform |
| Semantic Layer, Mesh | N/A (concepts only) | MetricFlow-powered Semantic Layer; cross-project `ref` |

Setup order for Phase 7: create free Developer account → Connections: BigQuery (upload a key for a dev SA or use OAuth) → link GitHub repo, set *Project subdirectory* = `dbt` → create **Development** environment (dataset `dbt_cloud_dev`) → develop once in the IDE → create **Production** environment → create a scheduled **job** (`dbt build`, tick *Generate docs on run* and *Run source freshness*) → create a **CI job** (trigger: pull requests, defer to Production) → open **Explorer** after a couple of runs.

Gotchas: the platform project must point at the `dbt/` subdirectory or nothing compiles; environment-level env vars ≠ job-level overrides (know both exist); the CI job needs the Production environment to have at least one successful run to defer to (same rule as your GCS manifest).

---

## 10. Exam-Prep Appendix

### 10.1 Section → study-guide topic map

Official outline lives in [dbt_Study_Guide_AI_Knowledge_Base.md](dbt_Study_Guide_AI_Knowledge_Base.md).

| Study-guide topic (v1.11) | TUTORIAL sections |
|---|---|
| 1. Developing & optimizing dbt models (incl. microbatch, `--empty`, `--sample`) | §4.1–4.5, §4.10 |
| 2. Managing model governance (contracts, versions, constraints) | §4.9 |
| 3. Debugging modeling errors (incl. flags) | §4.5 (flags), §8.2–8.4 (+ PROJECT 3.9 drills) |
| 4. Troubleshooting & optimizing pipelines | §4.2 (retry/clone), §8.4–8.6 |
| 5. Tests | §4.6 |
| 6. Documentation | §4.10 |
| 7. External dependencies | §4.11 + §4.2 (source freshness) |
| 8. State | §4.7–4.8 |
| Platform features (supplementary — exam is Core-centric) | §9 |

### 10.2 High-yield distinctions (exam bait)

- `dbt run` vs `dbt build` (tests gating downstream, DAG-ordered).
- `--defer` vs `dbt clone` (redirect refs vs copy relations).
- `state:modified` vs `state:modified+` (node vs node-and-descendants).
- `var()` vs `env_var()` (dbt vars vs OS environment; env_var for secrets).
- `source()` freshness (`loaded_at_field`) vs model freshness (doesn't exist — freshness is a *source* concept).
- Generic vs singular vs custom generic vs unit tests (§4.6 table).
- Materialization defaults & config precedence (§4.3, §4.5).
- `access: protected` default; contracts fail at *build* time; versions change `ref()` resolution.
- Snapshot strategies: timestamp (needs updated_at) vs check (column comparison).
- `is_incremental()` is false on first run and on `--full-refresh`.
- `--empty` builds zero-row refs/sources — tests still run, and they **pass on empty tables** (a `unique` test can't find duplicates in zero rows). It validates schema/logic, never data.
- Microbatch: no `is_incremental()` needed; upstream needs `event_time` too; failed batches retry individually.
- In `dbt build`, a test **FAIL skips downstream models**, but a `warn` doesn't block anything — `warn_if`/`error_if` thresholds are how you demote a failure. `--fail-fast` stops the whole run early; it doesn't unblock skips.
- Node selection with numbers bounds depth: `1+my_model` = model + first-degree parents only; `+my_model` = ALL ancestors.
- One dbt **source = one database + schema combination**; the tables within it are entries under that source (classic counting question).
- Constraints require `data_type` on the column when the contract is enforced — otherwise a *parsing* error, before any SQL runs.

### 10.3 Official resources

- **Local knowledge base:** [dbt_Study_Guide_AI_Knowledge_Base.md](dbt_Study_Guide_AI_Knowledge_Base.md) — official outline, logistics, doc links by topic, and the 10 worked sample questions
- Study guide (v1.11): https://www.getdbt.com/dbt-assets/certifications/dbt-certificate-study-guide-version-1-11
- Exam info & registration: https://www.getdbt.com/certifications/analytics-engineer-certification-exam
- dbt docs: https://docs.getdbt.com (Reference → especially *Node selection*, *Materializations*, *Tests*, *Deployment*)
- dbt Learn free courses: https://learn.getdbt.com (dbt Fundamentals, Materialization Fundamentals, Refactoring SQL for Modularity, Jinja/Macros/Packages, Advanced Testing, dbt Mesh — Model Governance)
- Recommended readings from the guide: *dbt viewpoint*, *How we structure our dbt projects*, *Refactoring legacy SQL to dbt*, *Test smarter not harder*, *To defer or to clone, that is the question* (all on docs.getdbt.com / the dbt blog)
- dbt Slack community channels: `#dbt-certification`, `#learn-on-demand`, `#advice-dbt-help`
- dbt-bigquery adapter docs: https://docs.getdbt.com/reference/resource-configs/bigquery-configs

### 10.4 Exam logistics & final-week strategy

**Logistics (v1.11):** 65 questions, 2 hours, online proctored, **65% to pass** (score shown immediately), $200 per attempt, certification valid 2 years, English or Japanese. Some unscored research questions are mixed in — indistinguishable, so treat every question as real.

**Question formats:** multiple-choice, fill-in-the-blank, matching, hotspot, build-list, and **DOMC** (Discrete Option Multiple Choice — options appear one at a time and you answer yes/no to each, so you can't compare or eliminate across options; you have to actually know the material, not test-take your way through).

**Final week:**

1. Re-read every row of the PROJECT.md traceability matrix; for any row you can't explain aloud, redo that project task.
2. Work the 10 sample questions in [dbt_Study_Guide_AI_Knowledge_Base.md](dbt_Study_Guide_AI_Knowledge_Base.md) cold and justify each answer — their themes (test `where` config, incremental suitability, git pull, `ref()` dependencies, source counting, `1+model` selection, `--empty` gotcha, constraint `data_type`, build skip vs warn thresholds, source schema verification) are exactly the exam's style.
3. Re-run the debugging drills (PROJECT 3.9) — the exam leans heavily on "here's an error, what happened?"
4. Skim §10.2 distinctions the morning of the exam, and for every scenario question ask: "which environment, command, and artifact is involved?"
