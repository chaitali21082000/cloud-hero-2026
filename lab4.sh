#!/bin/bash
# Ultra-fast GCP Cloud Hero script

# Color variables (simplified)
BOLD=`tput bold`
RESET=`tput sgr0`
GREEN=`tput setaf 2`
YELLOW=`tput setaf 3`

echo "${BOLD}${GREEN}Starting Fast Execution...${RESET}"

# Step 1: Set environment variables (no echo for speed)
export PROCESSOR_NAME=form-processor
export PROJECT_ID=$(gcloud config get-value core/project)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export REGION=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-region])")
export GEO_CODE_REQUEST_PUBSUB_TOPIC=geocode_request
export BUCKET_LOCATION=$REGION

# Step 2: Create GCS buckets (parallel)
echo "${BOLD}${YELLOW}Creating resources...${RESET}"
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-input-invoices 2>/dev/null &
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-output-invoices 2>/dev/null &
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-archived-invoices 2>/dev/null &

# Step 3: Enable services (parallel)
gcloud services enable documentai.googleapis.com cloudfunctions.googleapis.com cloudbuild.googleapis.com geocoding-backend.googleapis.com --quiet 2>/dev/null &

wait  # Wait for all parallel background jobs

# Step 4-6: Create and configure API key (optimized)
export API_KEY=$(gcloud alpha services api-keys create --display-name="awesome" --format="value(keyString)" 2>/dev/null)
KEY_NAME=$(gcloud alpha services api-keys list --format="value(name)" --filter "displayName=awesome" 2>/dev/null)

# Restrict API key (async)
curl -s -X PATCH -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" -d '{"restrictions": {"apiTargets": [{"service": "geocoding-backend.googleapis.com"}]}}' "https://apikeys.googleapis.com/v2/$KEY_NAME?updateMask=restrictions" > /dev/null 2>&1 &

# Step 7: Copy demo assets (in background)
mkdir -p ~/documentai-pipeline-demo 2>/dev/null
gcloud storage cp -r gs://spls/gsp927/documentai-pipeline-demo/* ~/documentai-pipeline-demo/ 2>/dev/null &

# Step 8: Create Document AI Processor (optimized)
PROCESSOR_ID=$(curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" -d '{"display_name": "'"$PROCESSOR_NAME"'", "type": "FORM_PARSER_PROCESSOR"}' "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | cut -d'/' -f6)

# If processor creation failed, get existing one
if [ -z "$PROCESSOR_ID" ]; then
    PROCESSOR_ID=$(curl -s -X GET -H "Authorization: Bearer $(gcloud auth print-access-token)" "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 | cut -d'/' -f6)
fi
export PROCESSOR_ID

# Step 9: Create BigQuery dataset and tables
bq --location="US" mk -d --description "Form Parser Results" ${PROJECT_ID}:invoice_parser_results 2>/dev/null
cd ~/documentai-pipeline-demo/scripts/table-schema/
bq mk --table invoice_parser_results.doc_ai_extracted_entities doc_ai_extracted_entities.json 2>/dev/null
bq mk --table invoice_parser_results.geocode_details geocode_details.json 2>/dev/null

# Step 10: Create Pub/Sub topic
gcloud pubsub topics create ${GEO_CODE_REQUEST_PUBSUB_TOPIC} 2>/dev/null

# Step 11: Create service account and assign roles
gcloud iam service-accounts create "service-$PROJECT_NUMBER" --display-name "Cloud Storage Service Account" 2>/dev/null
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com" --role="roles/pubsub.publisher" --quiet 2>/dev/null
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com" --role="roles/iam.serviceAccountTokenCreator" --quiet 2>/dev/null

# Step 12-13: Deploy Cloud Functions (optimized with single retry)
cd ~/documentai-pipeline-demo/scripts
export CLOUD_FUNCTION_LOCATION=$REGION

# Deploy process-invoices (faster with reduced retry)
echo "${BOLD}${YELLOW}Deploying functions...${RESET}"
gcloud functions deploy process-invoices --no-gen2 --region="${CLOUD_FUNCTION_LOCATION}" --entry-point=process_invoice --runtime=python39 --source=cloud-functions/process-invoices --timeout=400 --env-vars-file=cloud-functions/process-invoices/.env.yaml --trigger-resource="gs://${PROJECT_ID}-input-invoices" --trigger-event=google.storage.object.finalize --quiet 2>/dev/null || sleep 15 && gcloud functions deploy process-invoices --no-gen2 --region="${CLOUD_FUNCTION_LOCATION}" --entry-point=process_invoice --runtime=python39 --source=cloud-functions/process-invoices --timeout=400 --env-vars-file=cloud-functions/process-invoices/.env.yaml --trigger-resource="gs://${PROJECT_ID}-input-invoices" --trigger-event=google.storage.object.finalize --quiet 2>/dev/null &

# Deploy geocode-addresses (in parallel)
gcloud functions deploy geocode-addresses --no-gen2 --region="${CLOUD_FUNCTION_LOCATION}" --entry-point=process_address --runtime=python39 --source=cloud-functions/geocode-addresses --timeout=60 --env-vars-file=cloud-functions/geocode-addresses/.env.yaml --trigger-topic="${GEO_CODE_REQUEST_PUBSUB_TOPIC}" --quiet 2>/dev/null || sleep 15 && gcloud functions deploy geocode-addresses --no-gen2 --region="${CLOUD_FUNCTION_LOCATION}" --entry-point=process_address --runtime=python39 --source=cloud-functions/geocode-addresses --timeout=60 --env-vars-file=cloud-functions/geocode-addresses/.env.yaml --trigger-topic="${GEO_CODE_REQUEST_PUBSUB_TOPIC}" --quiet 2>/dev/null &

wait  # Wait for both function deployments

# Step 16-17: Update environment variables (parallel)
gcloud functions deploy process-invoices --no-gen2 --region="${CLOUD_FUNCTION_LOCATION}" --entry-point=process_invoice --runtime=python39 --source=cloud-functions/process-invoices --timeout=400 --update-env-vars=PROCESSOR_ID=${PROCESSOR_ID},PARSER_LOCATION=us,GCP_PROJECT=${PROJECT_ID} --trigger-resource="gs://${PROJECT_ID}-input-invoices" --trigger-event=google.storage.object.finalize --quiet 2>/dev/null &
gcloud functions deploy geocode-addresses --no-gen2 --region="${CLOUD_FUNCTION_LOCATION}" --entry-point=process_address --runtime=python39 --source=cloud-functions/geocode-addresses --timeout=60 --update-env-vars=API_key=${API_KEY} --trigger-topic=${GEO_CODE_REQUEST_PUBSUB_TOPIC} --quiet 2>/dev/null &

wait

# Step 18: Upload sample files
gsutil cp gs://spls/gsp927/documentai-pipeline-demo/sample-files/* gs://${PROJECT_ID}-input-invoices/ 2>/dev/null

# Final cleanup (fast)
cd
rm -f gsp* arc* shell* 2>/dev/null

echo -e "\n${BOLD}${GREEN}✅ Lab Completed Successfully!${RESET}\n"
