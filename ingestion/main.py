"""Olist ingestion: Kaggle -> GCS raw zone -> BigQuery raw_olist.

Cloud Run job. Idempotent per day: re-runs overwrite
the same GCS partition and WRITE_TRUNCATE the same BigQuery tables.

Required env vars:
    GCP_PROJECT  e.g. olist-analytics-501518
    BUCKET       e.g. olist-analytics-501518-datalake
"""

import datetime
import logging
import os
import tempfile

from google.cloud import bigquery, secretmanager, storage

KAGGLE_DATASET = "olistbr/brazilian-ecommerce"
RAW_DATASET = "raw_olist"
RAW_PREFIX = "raw/olist"

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("ingest")


def _load_kaggle_token() -> None:
    """Fetch the Kaggle API token from Secret Manager into the env var
    the kaggle client reads. Must run BEFORE `import kaggle`."""
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{os.environ['GCP_PROJECT']}/secrets/kaggle-credentials/versions/latest"
    token = client.access_secret_version(name=name).payload.data.decode().strip()
    os.environ["KAGGLE_API_TOKEN"] = token


def _download_from_kaggle(dest_dir: str) -> list[str]:
    """Download and unzip the Olist dataset; return the CSV filenames."""
    import kaggle  # deferred import: authenticates at import time

    kaggle.api.dataset_download_files(KAGGLE_DATASET, path=dest_dir, unzip=True)
    csvs = sorted(f for f in os.listdir(dest_dir) if f.endswith(".csv"))
    log.info("downloaded %d csv files from kaggle", len(csvs))
    return csvs


def _upload_to_gcs(src_dir: str, csvs: list[str], ingestion_date: str) -> dict[str, str]:
    """Upload each CSV to the dated raw-zone partition. Returns table -> gcs uri."""
    bucket = storage.Client().bucket(os.environ["BUCKET"])
    uris = {}
    for filename in csvs:
        table = filename.removesuffix(".csv")
        blob_name = f"{RAW_PREFIX}/{table}/ingestion_date={ingestion_date}/{filename}"
        bucket.blob(blob_name).upload_from_filename(os.path.join(src_dir, filename))
        uris[table] = f"gs://{os.environ['BUCKET']}/{blob_name}"
        log.info("uploaded %s", blob_name)
    return uris


def _load_to_bigquery(uris: dict[str, str]) -> dict[str, int]:
    """Load each GCS CSV into raw_olist via a temp table, adding _loaded_at.
    Returns table -> row count."""
    client = bigquery.Client(project=os.environ["GCP_PROJECT"])
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,
        autodetect=True,
        write_disposition="WRITE_TRUNCATE",
        # Olist review comments contain newlines inside quoted fields
        allow_quoted_newlines=True,
    )
    counts = {}
    for table, uri in uris.items():
        tmp = f"{RAW_DATASET}._tmp_{table}"
        client.load_table_from_uri(uri, tmp, job_config=job_config).result()
        client.query(
            f"""
            CREATE OR REPLACE TABLE `{RAW_DATASET}.{table}` AS
            SELECT *, CURRENT_TIMESTAMP() AS _loaded_at
            FROM `{tmp}`
            """
        ).result()
        client.delete_table(tmp)
        counts[table] = client.get_table(f"{RAW_DATASET}.{table}").num_rows
        log.info("loaded %s (%d rows)", table, counts[table])
    return counts


def run_ingestion() -> dict:
    """Full pipeline: Kaggle -> GCS -> BigQuery. Shared by both entrypoints."""
    ingestion_date = datetime.date.today().isoformat()
    _load_kaggle_token()

    with tempfile.TemporaryDirectory() as tmp_dir:
        csvs = _download_from_kaggle(tmp_dir)
        uris = _upload_to_gcs(tmp_dir, csvs, ingestion_date)

    counts = _load_to_bigquery(uris)
    return {"ingestion_date": ingestion_date, "tables": counts}


if __name__ == "__main__":
    # Cloud Run JOB entrypoint: run once to completion, exit non-zero on failure.
    result = run_ingestion()
    log.info("ingestion complete: %s", result)