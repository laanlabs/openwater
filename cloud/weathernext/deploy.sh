#!/bin/bash
# Stand up (or update) the WeatherNext publisher in openWater's Cloud project.
#
# Idempotent: every step is a create-if-missing or an update. Run it from
# the repo root as an owner of the project, as jason@laan.com — the account
# the WeatherNext grant is tied to, without which the linked dataset
# `weathernext_3` reads as empty.
#
#   CLOUDSDK_CORE_ACCOUNT=jason@laan.com cloud/weathernext/deploy.sh
#
# What it makes, all inside the free tier at two runs a day:
#   - a public bucket the app reads, openwater-weathernext (US, uniform access)
#   - a service account that may query BigQuery and write that bucket, and
#     nothing else
#   - a Cloud Run job built from this directory
#   - a Cloud Scheduler job that runs it at init + 8h35 for the 00Z and 12Z runs
#
# See docs/WEATHERNEXT.md for why the shape is what it is.
set -euo pipefail
cd "$(dirname "$0")"

PROJECT=${PROJECT:-openwaterapp-2e0f7}
REGION=${REGION:-us-east1}          # the dataset is in the US multi-region
BUCKET=${BUCKET:-openwater-weathernext}
JOB=weathernext-publish
SA_NAME=weathernext-publisher
SA="$SA_NAME@$PROJECT.iam.gserviceaccount.com"

echo "==> APIs"
gcloud services enable run.googleapis.com cloudscheduler.googleapis.com \
  cloudbuild.googleapis.com artifactregistry.googleapis.com \
  bigquery.googleapis.com storage.googleapis.com --project "$PROJECT"

echo "==> Bucket gs://$BUCKET (public read)"
if ! gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT" \
    --location=US --uniform-bucket-level-access --default-storage-class=STANDARD
fi
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member=allUsers --role=roles/storage.objectViewer --project "$PROJECT" >/dev/null

echo "==> Service account $SA"
if ! gcloud iam service-accounts describe "$SA" --project "$PROJECT" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" --project "$PROJECT" \
    --display-name="WeatherNext publisher (Cloud Run job)"
fi
# Run queries, read the linked dataset, write the bucket. No project-wide
# storage role: the job can touch this bucket and nothing else.
gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" \
  --role=roles/bigquery.jobUser --condition=None >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" \
  --role=roles/bigquery.dataViewer --condition=None >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member="serviceAccount:$SA" --role=roles/storage.objectAdmin --project "$PROJECT" >/dev/null

echo "==> Cloud Run job $JOB"
gcloud run jobs deploy "$JOB" --source . --project "$PROJECT" --region "$REGION" \
  --service-account "$SA" --tasks 1 --max-retries 1 --task-timeout 15m \
  --memory 1Gi --cpu 1 \
  --set-env-vars "PROJECT=$PROJECT,BUCKET=$BUCKET"

# Two runs a day, not four: a run bills ~8.5 GiB (measured 2026-09-13),
# and four a day is the whole free tier. The 00Z and 12Z runs, at init +
# 8h35, are ~510 GiB a month.
echo "==> Scheduler: the 00Z and 12Z runs, at init + 8h35 UTC"
SCHEDULE="35 8,20 * * *"
RUN_URI="https://$REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT/jobs/$JOB:run"
# The scheduler calls the job as the same service account, which needs
# leave to start it.
gcloud run jobs add-iam-policy-binding "$JOB" --project "$PROJECT" --region "$REGION" \
  --member="serviceAccount:$SA" --role=roles/run.invoker >/dev/null
if gcloud scheduler jobs describe "$JOB" --project "$PROJECT" --location "$REGION" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "$JOB" --project "$PROJECT" --location "$REGION" \
    --schedule "$SCHEDULE" --time-zone UTC --uri "$RUN_URI" --http-method POST \
    --oauth-service-account-email "$SA" --attempt-deadline 60s
else
  gcloud scheduler jobs create http "$JOB" --project "$PROJECT" --location "$REGION" \
    --schedule "$SCHEDULE" --time-zone UTC --uri "$RUN_URI" --http-method POST \
    --oauth-service-account-email "$SA" --attempt-deadline 60s
fi

echo "==> First run, now, so the bucket is not empty until the next slot"
gcloud run jobs execute "$JOB" --project "$PROJECT" --region "$REGION" --wait

echo
echo "Published: https://storage.googleapis.com/$BUCKET/manifest.json"
