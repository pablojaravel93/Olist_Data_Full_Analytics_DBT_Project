# ============================================================================
# deploy.ps1 — Build, push, and schedule the Olist ingestion Cloud Run JOB
#
# Run from the ingestion/ folder:  .\deploy.ps1
# Prereqs: gcloud authenticated, Docker Desktop running,
#          sa-ingestion + bucket + secret + raw_olist dataset already created.
# Idempotent: safe to re-run after code changes (rebuilds image, updates job).
# ============================================================================


#Run locally
$env:GCP_PROJECT = "olist-analytics-501518"
$env:BUCKET      = "olist-analytics-501518-datalake"
C:\EndToEnd_AnalyticsProject_Olist_Dataset\.venv\Scripts\python.exe ingestion\main.py

$ErrorActionPreference = "Stop"

# ---- Variables -------------------------------------------------------------
$PROJECT  = gcloud config get-value project
$REGION   = "us-central1"
$REPO     = "analytics"                       # Artifact Registry repo name
$IMAGE    = "$REGION-docker.pkg.dev/$PROJECT/$REPO/ingest-olist:latest"
$JOB      = "ingest-olist"
$SA       = "sa-ingestion@$PROJECT.iam.gserviceaccount.com"
$BUCKET   = "$PROJECT-datalake"
$SCHEDULE = "0 6 * * 1"                       # Mondays 06:00 (Scheduler default TZ: UTC)

Write-Host "Project: $PROJECT | Region: $REGION | Image: $IMAGE"

# ---- 1. Artifact Registry repo (create once, skip if it exists) ------------
$repoExists = gcloud artifacts repositories describe $REPO --location=$REGION 2>$null
if (-not $repoExists) {
    gcloud artifacts repositories create $REPO `
        --repository-format=docker --location=$REGION `
        --description="Olist analytics images"
}

# Let local docker push to Artifact Registry (writes to Docker config; harmless to repeat)
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

# ---- 2. Build & push the image ---------------------------------------------
docker build -t $IMAGE .
docker push $IMAGE

# ---- 3. Create/update the Cloud Run job ------------------------------------
# `jobs deploy` = create if missing, update if it exists.
gcloud run jobs deploy $JOB `
    --image=$IMAGE `
    --region=$REGION `
    --service-account=$SA `
    --set-env-vars="GCP_PROJECT=$PROJECT,BUCKET=$BUCKET" `
    --memory=1Gi `
    --cpu=1 `
    --task-timeout=900 `
    --max-retries=1

# ---- 4. Allow sa-ingestion to execute the job (needed by Scheduler) --------
gcloud run jobs add-iam-policy-binding $JOB `
    --region=$REGION `
    --member="serviceAccount:$SA" `
    --role="roles/run.invoker"

# ---- 5. Cloud Scheduler: weekly trigger via the jobs:run REST endpoint -----
$jobUri = "https://run.googleapis.com/v2/projects/$PROJECT/locations/$REGION/jobs/${JOB}:run"
$schedExists = gcloud scheduler jobs describe "$JOB-weekly" --location=$REGION 2>$null
if ($schedExists) {
    gcloud scheduler jobs update http "$JOB-weekly" `
        --location=$REGION --schedule=$SCHEDULE `
        --uri=$jobUri --http-method=POST `
        --oauth-service-account-email=$SA
} else {
    gcloud scheduler jobs create http "$JOB-weekly" `
        --location=$REGION --schedule=$SCHEDULE `
        --uri=$jobUri --http-method=POST `
        --oauth-service-account-email=$SA
}

Write-Host ""
Write-Host "Deployed. Useful commands:"
Write-Host "  gcloud run jobs execute $JOB --region=$REGION --wait     # run now"
Write-Host "  gcloud scheduler jobs run $JOB-weekly --location=$REGION # test the trigger"
Write-Host "  gcloud run jobs executions list --job=$JOB --region=$REGION"



