#!/bin/bash
set -e

echo "🚀 Starting FAST execution..."

# -------------------------------

# CONFIG

# -------------------------------

export PROJECT_ID=$(gcloud config get-value core/project)
export REGION="us-central1"
export PROCESSOR_NAME="form-processor"
export GEO_CODE_REQUEST_PUBSUB_TOPIC="geocode_request"

echo "Project: $PROJECT_ID"

# -------------------------------

# ENABLE APIS (parallelized)

# -------------------------------

echo "⚡ Enabling APIs..."
gcloud services enable 
documentai.googleapis.com 
cloudfunctions.googleapis.com 
cloudbuild.googleapis.com 
geocoding-backend.googleapis.com &

wait

# -------------------------------

# CREATE API KEY (fast + safe)

# -------------------------------

echo "🔑 Creating API key..."

KEY_NAME=$(gcloud services api-keys list 
--format="value(name)" 
--filter="displayName=awesome")

if [ -z "$KEY_NAME" ]; then
KEY_NAME=$(gcloud services api-keys create 
--display-name="awesome" 
--format="value(name)")
fi

API_KEY=$(gcloud services api-keys get-key-string $KEY_NAME 
--format="value(keyString)")

# Restrict API key

curl -s -X PATCH 
-H "Authorization: Bearer $(gcloud auth print-access-token)" 
-H "Content-Type: application/json" 
-d '{
"restrictions": {
"apiTargets": [
{"service": "geocoding-backend.googleapis.com"}
]
}
}' 
"https://apikeys.googleapis.com/v2/$KEY_NAME?updateMask=restrictions" >/dev/null

# -------------------------------

# DOWNLOAD FILES

# -------------------------------

echo "📦 Downloading lab files..."
mkdir -p ~/documentai-pipeline-demo
gcloud storage cp -r 
gs://spls/gsp927/documentai-pipeline-demo/* 
~/documentai-pipeline-demo/ >/dev/null

# -------------------------------

# CREATE STORAGE

# -------------------------------

echo "🪣 Creating buckets..."
gsutil mb -p $PROJECT_ID -l $REGION gs://${PROJECT_ID}-input-invoices || true
gsutil mb -p $PROJECT_ID -l $REGION gs://${PROJECT_ID}-output-invoices || true
gsutil mb -p $PROJECT_ID -l $REGION gs://${PROJECT_ID}-archived-invoices || true

# -------------------------------

# BIGQUERY

# -------------------------------

echo "📊 Creating BigQuery..."
bq --location=US mk -d ${PROJECT_ID}:invoice_parser_results || true

cd ~/documentai-pipeline-demo/scripts/table-schema/

bq mk --table invoice_parser_results.doc_ai_extracted_entities doc_ai_extracted_entities.json || true
bq mk --table invoice_parser_results.geocode_details geocode_details.json || true

# -------------------------------

# PUBSUB

# -------------------------------

echo "📨 Creating PubSub..."
gcloud pubsub topics create $GEO_CODE_REQUEST_PUBSUB_TOPIC || true

# -------------------------------

# SERVICE ACCOUNT PERMISSIONS

# -------------------------------

echo "🔐 Setting IAM..."

PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

gcloud projects add-iam-policy-binding $PROJECT_ID 
--member="serviceAccount:service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com" 
--role="roles/pubsub.publisher" >/dev/null

gcloud projects add-iam-policy-binding $PROJECT_ID 
--member="serviceAccount:service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com" 
--role="roles/iam.serviceAccountTokenCreator" >/dev/null

# -------------------------------

# CREATE PROCESSOR (fast)

# -------------------------------

echo "🧠 Creating Document AI processor..."

PROCESSOR_ID=$(curl -s -X POST 
-H "Authorization: Bearer $(gcloud auth print-access-token)" 
-H "Content-Type: application/json" 
-d "{
"display_name": "$PROCESSOR_NAME",
"type": "FORM_PARSER_PROCESSOR"
}" 
"https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" 
| jq -r '.name' | awk -F'/' '{print $NF}')

echo "Processor ID: $PROCESSOR_ID"

# -------------------------------

# DEPLOY FUNCTIONS (with retry)

# -------------------------------

cd ~/documentai-pipeline-demo/scripts

deploy() {
NAME=$1
shift

for i in {1..5}; do
echo "Deploying $NAME (attempt $i)..."
if gcloud functions deploy "$NAME" "$@"; then
return 0
fi
sleep 15
done

echo "❌ Failed: $NAME"
exit 1
}

# process-invoices

deploy process-invoices 
--no-gen2 
--region=$REGION 
--entry-point=process_invoice 
--runtime=python39 
--source=cloud-functions/process-invoices 
--timeout=400 
--set-env-vars=PROCESSOR_ID=$PROCESSOR_ID,PARSER_LOCATION=us,GCP_PROJECT=$PROJECT_ID 
--trigger-resource=gs://${PROJECT_ID}-input-invoices 
--trigger-event=google.storage.object.finalize

# geocode-addresses

deploy geocode-addresses 
--no-gen2 
--region=$REGION 
--entry-point=process_address 
--runtime=python39 
--source=cloud-functions/geocode-addresses 
--timeout=60 
--set-env-vars=API_key=$API_KEY 
--trigger-topic=$GEO_CODE_REQUEST_PUBSUB_TOPIC

# -------------------------------

# TEST PIPELINE

# -------------------------------

echo "🧪 Uploading test files..."
gsutil cp 
gs://spls/gsp927/documentai-pipeline-demo/sample-files/* 
gs://${PROJECT_ID}-input-invoices/ >/dev/null

echo "🎉 DONE — Pipeline triggered!"
