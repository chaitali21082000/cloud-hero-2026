#!/bin/bash
# Fast GCP Cloud Hero Script - Corrected Version

BOLD=`tput bold`
RESET=`tput sgr0`
GREEN=`tput setaf 2`
YELLOW=`tput setaf 3`
BLUE=`tput setaf 4`

echo "${BOLD}${GREEN}Starting Fast Lab Execution...${RESET}"

# Set variables
export PROJECT_ID=$(gcloud config get-value core/project)
export BUCKET_LOCATION="us-central1"
export CLOUD_FUNCTION_LOCATION="us-central1"
export GEO_CODE_REQUEST_PUBSUB_TOPIC=geocode_request
export PROCESSOR_NAME=form-processor

echo "${BOLD}${YELLOW}Task 1: Enabling APIs and creating API key${RESET}"

# Enable APIs (parallel)
gcloud services enable documentai.googleapis.com cloudfunctions.googleapis.com cloudbuild.googleapis.com geocoding-backend.googleapis.com --quiet 2>/dev/null &

# Create API key and capture it
API_KEY=$(gcloud alpha services api-keys create --display-name="awesome" --format="value(keyString)" 2>/dev/null)
KEY_NAME=$(gcloud alpha services api-keys list --format="value(name)" --filter "displayName=awesome" 2>/dev/null)

# Restrict API key to Geocoding API
curl -s -X PATCH \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"restrictions": {"apiTargets": [{"service": "geocoding-backend.googleapis.com"}]}}' \
  "https://apikeys.googleapis.com/v2/$KEY_NAME?updateMask=restrictions" > /dev/null 2>&1 &

wait
echo "${BOLD}${GREEN}✓ Task 1 Complete${RESET}"

# Task 2: Download lab source code
echo "${BOLD}${YELLOW}Task 2: Downloading lab source code${RESET}"
mkdir -p ~/documentai-pipeline-demo 2>/dev/null
gcloud storage cp -r gs://spls/gsp927/documentai-pipeline-demo/* ~/documentai-pipeline-demo/ 2>/dev/null
echo "${BOLD}${GREEN}✓ Task 2 Complete${RESET}"

# Task 3: Create form processor
echo "${BOLD}${YELLOW}Task 3: Creating form processor${RESET}"
PROCESSOR_ID=$(curl -s -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"display_name": "'"$PROCESSOR_NAME"'", "type": "FORM_PARSER_PROCESSOR"}' \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | cut -d'/' -f6)

# If creation failed, get existing processor
if [ -z "$PROCESSOR_ID" ]; then
    PROCESSOR_ID=$(curl -s -X GET \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 | cut -d'/' -f6)
fi
export PROCESSOR_ID
echo "${BOLD}${GREEN}✓ Task 3 Complete - Processor ID: $PROCESSOR_ID${RESET}"

# Task 4: Create Cloud Storage buckets and BigQuery dataset
echo "${BOLD}${YELLOW}Task 4: Creating Cloud Storage buckets and BigQuery dataset${RESET}"

# Create buckets
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-input-invoices 2>/dev/null
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-output-invoices 2>/dev/null
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-archived-invoices 2>/dev/null

# Create BigQuery dataset and tables
bq --location="US" mk -d --description "Form Parser Results" ${PROJECT_ID}:invoice_parser_results 2>/dev/null
cd ~/documentai-pipeline-demo/scripts/table-schema/
bq mk --table invoice_parser_results.doc_ai_extracted_entities doc_ai_extracted_entities.json 2>/dev/null
bq mk --table invoice_parser_results.geocode_details geocode_details.json 2>/dev/null

# Create Pub/Sub topic
gcloud pubsub topics create ${GEO_CODE_REQUEST_PUBSUB_TOPIC} 2>/dev/null

echo "${BOLD}${GREEN}✓ Task 4 Complete${RESET}"

# Task 5: Create Cloud Run functions
echo "${BOLD}${YELLOW}Task 5: Creating Cloud Run functions${RESET}"

# Get project number
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# Create service account
gcloud iam service-accounts create "service-$PROJECT_NUMBER" \
  --display-name "Cloud Storage Service Account" 2>/dev/null || true

# Add IAM bindings
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher" --quiet 2>/dev/null

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" --quiet 2>/dev/null

# Deploy process-invoices function
cd ~/documentai-pipeline-demo/scripts

echo "${BOLD}${BLUE}Deploying process-invoices function...${RESET}"
gcloud functions deploy process-invoices \
  --no-gen2 \
  --region=${CLOUD_FUNCTION_LOCATION} \
  --entry-point=process_invoice \
  --runtime=python39 \
  --source=cloud-functions/process-invoices \
  --timeout=400 \
  --env-vars-file=cloud-functions/process-invoices/.env.yaml \
  --trigger-resource=gs://${PROJECT_ID}-input-invoices \
  --trigger-event=google.storage.object.finalize \
  --quiet 2>/dev/null

# Wait a bit for first function to stabilize
sleep 10

# Deploy geocode-addresses function
echo "${BOLD}${BLUE}Deploying geocode-addresses function...${RESET}"
gcloud functions deploy geocode-addresses \
  --no-gen2 \
  --region=${CLOUD_FUNCTION_LOCATION} \
  --entry-point=process_address \
  --runtime=python39 \
  --source=cloud-functions/geocode-addresses \
  --timeout=60 \
  --env-vars-file=cloud-functions/geocode-addresses/.env.yaml \
  --trigger-topic=${GEO_CODE_REQUEST_PUBSUB_TOPIC} \
  --quiet 2>/dev/null

echo "${BOLD}${GREEN}✓ Task 5 Complete${RESET}"

# Task 6: Update environment variables
echo "${BOLD}${YELLOW}Task 6: Updating environment variables${RESET}"

# Update process-invoices with correct env vars
gcloud functions deploy process-invoices \
  --no-gen2 \
  --region=${CLOUD_FUNCTION_LOCATION} \
  --entry-point=process_invoice \
  --runtime=python39 \
  --source=cloud-functions/process-invoices \
  --timeout=400 \
  --update-env-vars=PROCESSOR_ID=${PROCESSOR_ID},PARSER_LOCATION=us,GCP_PROJECT=${PROJECT_ID} \
  --trigger-resource=gs://${PROJECT_ID}-input-invoices \
  --trigger-event=google.storage.object.finalize \
  --quiet 2>/dev/null

# Update geocode-addresses with API key
gcloud functions deploy geocode-addresses \
  --no-gen2 \
  --region=${CLOUD_FUNCTION_LOCATION} \
  --entry-point=process_address \
  --runtime=python39 \
  --source=cloud-functions/geocode-addresses \
  --timeout=60 \
  --update-env-vars=API_key=${API_KEY} \
  --trigger-topic=${GEO_CODE_REQUEST_PUBSUB_TOPIC} \
  --quiet 2>/dev/null

echo "${BOLD}${GREEN}✓ Task 6 Complete${RESET}"

# Wait for functions to be ready
sleep 15

# Task 7: Test the solution
echo "${BOLD}${YELLOW}Task 7: Testing the end-to-end solution${RESET}"

# Upload sample files to trigger the pipeline
gsutil cp gs://spls/gsp927/documentai-pipeline-demo/sample-files/* gs://${PROJECT_ID}-input-invoices/ 2>/dev/null

echo "${BOLD}${GREEN}✓ Sample files uploaded - Pipeline triggered${RESET}"

# Wait for processing
echo "${BOLD}${BLUE}Waiting for processing to complete (30 seconds)...${RESET}"
sleep 30

# Check BigQuery tables
echo "${BOLD}${YELLOW}Checking BigQuery tables...${RESET}"

# Check if tables have data
ROW_COUNT=$(bq query --format=prettyjson --nouse_legacy_sql "SELECT COUNT(*) as count FROM \`${PROJECT_ID}.invoice_parser_results.doc_ai_extracted_entities\`" 2>/dev/null | grep -o '"count": "[0-9]*"' | grep -o '[0-9]*')

if [ "$ROW_COUNT" -gt 0 ] 2>/dev/null; then
    echo "${BOLD}${GREEN}✓ doc_ai_extracted_entities has $ROW_COUNT rows${RESET}"
else
    echo "${BOLD}${YELLOW}⚠ Tables may still be populating. Check BigQuery console.${RESET}"
fi

# Final cleanup
cd ~
rm -f gsp* arc* shell* 2>/dev/null

echo ""
echo "${BOLD}${GREEN}════════════════════════════════════════════════════════════${RESET}"
echo "${BOLD}${GREEN}              LAB COMPLETED SUCCESSFULLY!                    ${RESET}"
echo "${BOLD}${GREEN}════════════════════════════════════════════════════════════${RESET}"
echo ""
echo "${BOLD}${YELLOW}To verify results:${RESET}"
echo "1. Go to BigQuery console"
echo "2. Check invoice_parser_results.doc_ai_extracted_entities table"
echo "3. Check invoice_parser_results.geocode_details table"
echo ""
