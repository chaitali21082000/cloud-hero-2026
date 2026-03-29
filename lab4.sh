#!/bin/bash
# Fixed GCP Cloud Hero Script - With Debugging

BOLD=`tput bold`
RESET=`tput sgr0`
GREEN=`tput setaf 2`
YELLOW=`tput setaf 3`
BLUE=`tput setaf 4`
RED=`tput setaf 1`

echo "${BOLD}${GREEN}Starting Lab Execution with Debugging...${RESET}"

# Set variables
export PROJECT_ID=$(gcloud config get-value core/project)
export BUCKET_LOCATION="us-central1"
export CLOUD_FUNCTION_LOCATION="us-central1"
export GEO_CODE_REQUEST_PUBSUB_TOPIC=geocode_request
export PROCESSOR_NAME=form-processor

echo "${BOLD}${YELLOW}Task 1: Enabling APIs and creating API key${RESET}"

# Enable APIs
gcloud services enable documentai.googleapis.com --quiet
gcloud services enable cloudfunctions.googleapis.com --quiet
gcloud services enable cloudbuild.googleapis.com --quiet
gcloud services enable geocoding-backend.googleapis.com --quiet
gcloud services enable bigquery.googleapis.com --quiet
gcloud services enable bigquerydatatransfer.googleapis.com --quiet

# Create API key
echo "${BOLD}${BLUE}Creating API key...${RESET}"
API_KEY=$(gcloud alpha services api-keys create --display-name="awesome" --format="value(keyString)" 2>/dev/null)
KEY_NAME=$(gcloud alpha services api-keys list --format="value(name)" --filter "displayName=awesome" 2>/dev/null)

# Restrict API key
curl -s -X PATCH \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"restrictions": {"apiTargets": [{"service": "geocoding-backend.googleapis.com"}]}}' \
  "https://apikeys.googleapis.com/v2/$KEY_NAME?updateMask=restrictions" > /dev/null 2>&1

echo "${BOLD}${GREEN}✓ API Key created: ${API_KEY}${RESET}"

# Task 2: Download source code
echo "${BOLD}${YELLOW}Task 2: Downloading lab source code${RESET}"
rm -rf ~/documentai-pipeline-demo
mkdir -p ~/documentai-pipeline-demo
gsutil cp -r gs://spls/gsp927/documentai-pipeline-demo/* ~/documentai-pipeline-demo/

# Task 3: Create form processor
echo "${BOLD}${YELLOW}Task 3: Creating form processor${RESET}"
# Try to create processor
PROCESSOR_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"display_name": "'"$PROCESSOR_NAME"'", "type": "FORM_PARSER_PROCESSOR"}' \
  "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors")

# Extract processor ID
PROCESSOR_ID=$(echo $PROCESSOR_RESPONSE | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | cut -d'/' -f6)

# If creation failed, get existing processor
if [ -z "$PROCESSOR_ID" ]; then
    PROCESSOR_ID=$(curl -s -X GET \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 | cut -d'/' -f6)
fi

export PROCESSOR_ID
echo "${BOLD}${GREEN}✓ Processor ID: $PROCESSOR_ID${RESET}"

# Task 4: Create buckets and BigQuery
echo "${BOLD}${YELLOW}Task 4: Creating Cloud Storage buckets and BigQuery dataset${RESET}"

# Create buckets (force recreate)
gsutil rm -r gs://${PROJECT_ID}-input-invoices 2>/dev/null
gsutil rm -r gs://${PROJECT_ID}-output-invoices 2>/dev/null
gsutil rm -r gs://${PROJECT_ID}-archived-invoices 2>/dev/null

gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-input-invoices
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-output-invoices
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-archived-invoices

# Create BigQuery dataset (force recreate)
bq rm -r -f -d ${PROJECT_ID}:invoice_parser_results 2>/dev/null
bq --location="US" mk -d --description "Form Parser Results" ${PROJECT_ID}:invoice_parser_results

cd ~/documentai-pipeline-demo/scripts/table-schema/
bq mk --table invoice_parser_results.doc_ai_extracted_entities doc_ai_extracted_entities.json
bq mk --table invoice_parser_results.geocode_details geocode_details.json

# Create Pub/Sub topic
gcloud pubsub topics delete ${GEO_CODE_REQUEST_PUBSUB_TOPIC} 2>/dev/null
gcloud pubsub topics create ${GEO_CODE_REQUEST_PUBSUB_TOPIC}

echo "${BOLD}${GREEN}✓ Resources created${RESET}"

# Task 5: Create service account and deploy functions
echo "${BOLD}${YELLOW}Task 5: Creating service account and deploying functions${RESET}"

PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# Create service account
gcloud iam service-accounts create "service-$PROJECT_NUMBER" \
  --display-name "Cloud Storage Service Account" 2>/dev/null || true

# Add IAM bindings
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher" --quiet

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" --quiet

# Add additional required roles
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor" --quiet

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin" --quiet

# Deploy process-invoices function
cd ~/documentai-pipeline-demo/scripts

echo "${BOLD}${BLUE}Deploying process-invoices function...${RESET}"
gcloud functions deploy process-invoices \
  --gen2 \
  --region=${CLOUD_FUNCTION_LOCATION} \
  --entry-point=process_invoice \
  --runtime=python39 \
  --source=cloud-functions/process-invoices \
  --timeout=540 \
  --memory=512MB \
  --trigger-bucket=gs://${PROJECT_ID}-input-invoices \
  --set-env-vars=PROCESSOR_ID=${PROCESSOR_ID},PARSER_LOCATION=us,GCP_PROJECT=${PROJECT_ID} \
  --service-account=service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com \
  --quiet

# Wait for deployment
sleep 20

# Deploy geocode-addresses function
echo "${BOLD}${BLUE}Deploying geocode-addresses function...${RESET}"
gcloud functions deploy geocode-addresses \
  --gen2 \
  --region=${CLOUD_FUNCTION_LOCATION} \
  --entry-point=process_address \
  --runtime=python39 \
  --source=cloud-functions/geocode-addresses \
  --timeout=120 \
  --memory=256MB \
  --trigger-topic=${GEO_CODE_REQUEST_PUBSUB_TOPIC} \
  --set-env-vars=API_key=${API_KEY} \
  --service-account=service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com \
  --quiet

echo "${BOLD}${GREEN}✓ Functions deployed${RESET}"

# Wait for functions to be ready
echo "${BOLD}${BLUE}Waiting 30 seconds for functions to stabilize...${RESET}"
sleep 30

# Task 7: Test the solution
echo "${BOLD}${YELLOW}Task 7: Testing the end-to-end solution${RESET}"

# Clear buckets first
gsutil rm -f gs://${PROJECT_ID}-input-invoices/* 2>/dev/null
gsutil rm -f gs://${PROJECT_ID}-output-invoices/* 2>/dev/null
gsutil rm -f gs://${PROJECT_ID}-archived-invoices/* 2>/dev/null

# Upload sample files
echo "${BOLD}${BLUE}Uploading sample files...${RESET}"
gsutil cp gs://spls/gsp927/documentai-pipeline-demo/sample-files/* gs://${PROJECT_ID}-input-invoices/

# Check function logs
echo "${BOLD}${BLUE}Checking function execution...${RESET}"
sleep 10

# Monitor logs for processing
echo "${BOLD}${YELLOW}Monitoring function logs (this may take 1-2 minutes)...${RESET}"
for i in {1..12}; do
    echo -n "."
    sleep 10
done
echo ""

# Check function logs
echo "${BOLD}${BLUE}Recent function logs:${RESET}"
gcloud functions logs read process-invoices --region=${CLOUD_FUNCTION_LOCATION} --limit=20 2>/dev/null

# Verify BigQuery tables
echo "${BOLD}${YELLOW}Verifying BigQuery tables...${RESET}"

# Check doc_ai_extracted_entities
ROW_COUNT1=$(bq query --format=prettyjson --nouse_legacy_sql "SELECT COUNT(*) as count FROM \`${PROJECT_ID}.invoice_parser_results.doc_ai_extracted_entities\`" 2>/dev/null | grep -o '"count": "[0-9]*"' | grep -o '[0-9]*')

# Check geocode_details
ROW_COUNT2=$(bq query --format=prettyjson --nouse_legacy_sql "SELECT COUNT(*) as count FROM \`${PROJECT_ID}.invoice_parser_results.geocode_details\`" 2>/dev/null | grep -o '"count": "[0-9]*"' | grep -o '[0-9]*')

echo ""
if [ "$ROW_COUNT1" -gt 0 ] 2>/dev/null; then
    echo "${BOLD}${GREEN}✓ doc_ai_extracted_entities has $ROW_COUNT1 rows${RESET}"
else
    echo "${BOLD}${RED}✗ doc_ai_extracted_entities is empty${RESET}"
    echo "${BOLD}${YELLOW}Checking for errors...${RESET}"
    gcloud functions logs read process-invoices --region=${CLOUD_FUNCTION_LOCATION} --limit=50 2>/dev/null | grep -i error
fi

if [ "$ROW_COUNT2" -gt 0 ] 2>/dev/null; then
    echo "${BOLD}${GREEN}✓ geocode_details has $ROW_COUNT2 rows${RESET}"
else
    echo "${BOLD}${RED}✗ geocode_details is empty${RESET}"
fi

# If tables are empty, show troubleshooting steps
if [ -z "$ROW_COUNT1" ] || [ "$ROW_COUNT1" -eq 0 ] 2>/dev/null; then
    echo ""
    echo "${BOLD}${RED}════════════════════════════════════════════════════════════${RESET}"
    echo "${BOLD}${RED}           TROUBLESHOOTING REQUIRED                          ${RESET}"
    echo "${BOLD}${RED}════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo "${BOLD}${YELLOW}Please run these commands manually to check:${RESET}"
    echo ""
    echo "1. Check Cloud Function logs:"
    echo "   gcloud functions logs read process-invoices --region=us-central1"
    echo ""
    echo "2. Verify processor exists:"
    echo "   echo \$PROCESSOR_ID"
    echo ""
    echo "3. Manually trigger the function:"
    echo "   gsutil cp ~/documentai-pipeline-demo/sample-files/invoice_1.pdf gs://${PROJECT_ID}-input-invoices/"
    echo ""
    echo "4. Check if files were uploaded:"
    echo "   gsutil ls gs://${PROJECT_ID}-input-invoices/"
    echo ""
    echo "5. Verify API key is valid:"
    echo "   echo \$API_KEY"
    echo ""
fi

# Final cleanup
cd ~
rm -f gsp* arc* shell* 2>/dev/null

echo ""
echo "${BOLD}${GREEN}════════════════════════════════════════════════════════════${RESET}"
echo "${BOLD}${GREEN}              SCRIPT EXECUTION COMPLETE                       ${RESET}"
echo "${BOLD}${GREEN}════════════════════════════════════════════════════════════${RESET}"
echo ""

if [ "$ROW_COUNT1" -gt 0 ] 2>/dev/null; then
    echo "${BOLD}${GREEN}✓ Lab completed successfully! Data is in BigQuery.${RESET}"
else
    echo "${BOLD}${YELLOW}⚠ Tables are empty. Use the troubleshooting steps above.${RESET}"
    echo "${BOLD}${YELLOW}⚠ You may need to wait 2-3 more minutes for processing.${RESET}"
fi
