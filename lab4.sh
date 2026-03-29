clear
#!/bin/bash
set -e

# ================= COLORS =================
RED=$(tput setaf 1); GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3); BLUE=$(tput setaf 4)
MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6)
BOLD=$(tput bold); RESET=$(tput sgr0)

echo "${BOLD}${GREEN}⚡ Starting FAST execution...${RESET}"

# ================= STEP 1 =================
echo "${GREEN}Setting environment variables${RESET}"

export PROCESSOR_NAME=form-processor
export PROJECT_ID=$(gcloud config get-value core/project 2>/dev/null)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")

REGION=$(gcloud compute project-info describe \
--format="value(commonInstanceMetadata.items[google-compute-default-region])")

export GEO_CODE_REQUEST_PUBSUB_TOPIC=geocode_request
export BUCKET_LOCATION=$REGION

ACCESS_TOKEN=$(gcloud auth print-access-token)

# ================= STEP 2 =================
echo "${YELLOW}Creating buckets (parallel)${RESET}"

gsutil mb -p "$PROJECT_ID" -l "$BUCKET_LOCATION" gs://${PROJECT_ID}-input-invoices &
gsutil mb -p "$PROJECT_ID" -l "$BUCKET_LOCATION" gs://${PROJECT_ID}-output-invoices &
gsutil mb -p "$PROJECT_ID" -l "$BUCKET_LOCATION" gs://${PROJECT_ID}-archived-invoices &
wait

# ================= STEP 3 =================
echo "${BLUE}Enabling APIs (parallel)${RESET}"

gcloud services enable documentai.googleapis.com &
gcloud services enable cloudfunctions.googleapis.com &
gcloud services enable cloudbuild.googleapis.com &
gcloud services enable geocoding-backend.googleapis.com &
wait

# ================= STEP 4 =================
echo "${MAGENTA}Creating API key${RESET}"
gcloud alpha services api-keys create --display-name="awesome" >/dev/null

# ================= STEP 5 =================
echo "${CYAN}Fetching API key${RESET}"

KEY_NAME=$(gcloud alpha services api-keys list \
--filter="displayName=awesome" \
--format="value(name)")

API_KEY=$(gcloud alpha services api-keys get-key-string "$KEY_NAME" \
--format="value(keyString)")

# ================= STEP 6 =================
echo "${RED}Restricting API key${RESET}"

curl -s -X PATCH \
-H "Authorization: Bearer $ACCESS_TOKEN" \
-H "Content-Type: application/json" \
-d '{"restrictions":{"apiTargets":[{"service":"geocoding-backend.googleapis.com"}]}}' \
"https://apikeys.googleapis.com/v2/$KEY_NAME?updateMask=restrictions" >/dev/null

# ================= STEP 7 =================
echo "${GREEN}Copying assets${RESET}"

mkdir -p ~/documentai-pipeline-demo
gcloud storage cp -r gs://spls/gsp927/documentai-pipeline-demo/* \
~/documentai-pipeline-demo/ >/dev/null

# ================= STEP 8 =================
echo "${YELLOW}Creating Document AI Processor${RESET}"

curl -s -X POST \
-H "Authorization: Bearer $ACCESS_TOKEN" \
-H "Content-Type: application/json" \
-d "{\"display_name\":\"$PROCESSOR_NAME\",\"type\":\"FORM_PARSER_PROCESSOR\"}" \
"https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" >/dev/null

# ================= STEP 9 =================
echo "${BLUE}BigQuery setup${RESET}"

bq --location=US mk -d ${PROJECT_ID}:invoice_parser_results >/dev/null

cd ~/documentai-pipeline-demo/scripts/table-schema/

bq mk --table invoice_parser_results.doc_ai_extracted_entities doc_ai_extracted_entities.json >/dev/null
bq mk --table invoice_parser_results.geocode_details geocode_details.json >/dev/null

# ================= STEP 10 =================
echo "${MAGENTA}Creating PubSub topic${RESET}"
gcloud pubsub topics create ${GEO_CODE_REQUEST_PUBSUB_TOPIC} >/dev/null

# ================= STEP 11 (FIXED) =================
echo "${CYAN}Fixing IAM (CRITICAL)${RESET}"

# Get correct GCS service account
GCS_SA=$(gsutil kms serviceaccount -p $PROJECT_ID)

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$GCS_SA" \
  --role="roles/pubsub.publisher" >/dev/null

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$GCS_SA" \
  --role="roles/iam.serviceAccountTokenCreator" >/dev/null

# ================= STEP 12 =================
cd ~/documentai-pipeline-demo/scripts
export CLOUD_FUNCTION_LOCATION=$REGION

# ================= DEPLOY FUNCTION =================
deploy() {
  NAME=$1
  shift
  for i in {1..10}; do
    echo "Deploying $NAME (Attempt $i)..."
    if gcloud functions deploy "$NAME" "$@" >/dev/null 2>&1; then
      echo "✅ $NAME deployed"
      return 0
    fi
    sleep 10
  done
  echo "❌ $NAME failed"
  exit 1
}

# ================= STEP 13 =================
deploy process-invoices \
--no-gen2 \
--region="$CLOUD_FUNCTION_LOCATION" \
--entry-point=process_invoice \
--runtime=python39 \
--source=cloud-functions/process-invoices \
--timeout=400 \
--env-vars-file=cloud-functions/process-invoices/.env.yaml \
--trigger-resource="gs://${PROJECT_ID}-input-invoices" \
--trigger-event=google.storage.object.finalize

# ================= STEP 14 =================
deploy geocode-addresses \
--no-gen2 \
--region="$CLOUD_FUNCTION_LOCATION" \
--entry-point=process_address \
--runtime=python39 \
--source=cloud-functions/geocode-addresses \
--timeout=60 \
--env-vars-file=cloud-functions/geocode-addresses/.env.yaml \
--trigger-topic="${GEO_CODE_REQUEST_PUBSUB_TOPIC}"

# ================= STEP 15 =================
echo "${YELLOW}Fetching Processor ID${RESET}"

PROCESSOR_ID=$(curl -s -X GET \
-H "Authorization: Bearer $ACCESS_TOKEN" \
"https://documentai.googleapis.com/v1/projects/$PROJECT_ID/locations/us/processors" \
| grep -oP 'processors/\K[^"]+' | head -1)

# ================= STEP 16 =================
deploy process-invoices \
--update-env-vars=PROCESSOR_ID=${PROCESSOR_ID},PARSER_LOCATION=us,GCP_PROJECT=${PROJECT_ID} \
--no-gen2 \
--region="$CLOUD_FUNCTION_LOCATION" \
--entry-point=process_invoice \
--runtime=python39 \
--source=cloud-functions/process-invoices \
--timeout=400 \
--trigger-resource=gs://${PROJECT_ID}-input-invoices \
--trigger-event=google.storage.object.finalize

# ================= STEP 17 =================
deploy geocode-addresses \
--update-env-vars=API_key=${API_KEY} \
--no-gen2 \
--region="$CLOUD_FUNCTION_LOCATION" \
--entry-point=process_address \
--runtime=python39 \
--source=cloud-functions/geocode-addresses \
--timeout=60 \
--trigger-topic=${GEO_CODE_REQUEST_PUBSUB_TOPIC}

# ================= STEP 18 =================
echo "${CYAN}Uploading sample files${RESET}"

gsutil -m cp gs://spls/gsp927/documentai-pipeline-demo/sample-files/* \
gs://${PROJECT_ID}-input-invoices/ >/dev/null

# ================= CRITICAL WAIT =================
echo "${YELLOW}Waiting for pipeline to process (IMPORTANT)${RESET}"
sleep 60

# ================= CLEANUP =================
cd ~
rm -f gsp* arc* shell* 2>/dev/null || true

echo "${BOLD}${GREEN}🚀 LAB COMPLETED SUCCESSFULLY (TASK 7 FIXED)${RESET}"
