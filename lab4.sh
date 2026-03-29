#!/bin/bash
# GCP Cloud Hero - Document AI Pipeline Setup Script
# Run this script in Cloud Shell to automate the lab setup.

# Exit on error
set -e

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Get Project Variables
export PROJECT_ID=$(gcloud config get-value core/project)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export BUCKET_LOCATION="us-east1"
export CLOUD_FUNCTION_LOCATION="us-east1"
export GEO_CODE_REQUEST_PUBSUB_TOPIC="geocode_request"

print_status "Starting setup for Project: $PROJECT_ID"

# --------------------------------------------------------------
# TASK 1: Enable APIs
# --------------------------------------------------------------
print_status "Task 1: Enabling required APIs..."
gcloud services enable documentai.googleapis.com
gcloud services enable cloudfunctions.googleapis.com
gcloud services enable cloudbuild.googleapis.com
gcloud services enable geocoding-backend.googleapis.com
print_status "APIs enabled."

# --------------------------------------------------------------
# TASK 2: Download Source Code
# --------------------------------------------------------------
print_status "Task 2: Downloading lab source code..."
mkdir -p ./documentai-pipeline-demo
gcloud storage cp -r gs://spls/gsp927/documentai-pipeline-demo/* ~/documentai-pipeline-demo/
print_status "Source code downloaded."

# --------------------------------------------------------------
# TASK 3: Create Form Processor (Manual via UI warning)
# --------------------------------------------------------------
print_warning "Task 3: Please create the 'form-processor' in the Document AI Console manually."
print_warning "Waiting 15 seconds for you to read..."
sleep 15

# --------------------------------------------------------------
# TASK 4: Create Buckets, BigQuery Dataset, and Pub/Sub Topic
# --------------------------------------------------------------
print_status "Task 4: Creating Cloud Storage buckets..."
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-input-invoices
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-output-invoices
gsutil mb -c standard -l ${BUCKET_LOCATION} -b on gs://${PROJECT_ID}-archived-invoices

print_status "Creating BigQuery dataset and tables..."
bq --location="US" mk -d --description "Form Parser Results" ${PROJECT_ID}:invoice_parser_results
cd ~/documentai-pipeline-demo/scripts/table-schema/
bq mk --table invoice_parser_results.doc_ai_extracted_entities doc_ai_extracted_entities.json
bq mk --table invoice_parser_results.geocode_details geocode_details.json
cd ~/

print_status "Creating Pub/Sub topic..."
gcloud pubsub topics create ${GEO_CODE_REQUEST_PUBSUB_TOPIC}

# --------------------------------------------------------------
# TASK 5: Deploy Cloud Run Functions
# --------------------------------------------------------------
print_status "Task 5: Setting up IAM permissions for Cloud Storage..."
# Grant necessary permissions to avoid errors
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher" 2>/dev/null || true

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" 2>/dev/null || true

print_status "Deploying 'process-invoices' function (this takes ~2-3 minutes)..."
cd ~/documentai-pipeline-demo/scripts
gcloud functions deploy process-invoices \
  --no-gen2 \
  --region=${CLOUD_FUNCTION_LOCATION} \
  --entry-point=process_invoice \
  --runtime=python39 \
  --source=cloud-functions/process-invoices \
  --timeout=400 \
  --env-vars-file=cloud-functions/process-invoices/.env.yaml \
  --trigger-resource=gs://${PROJECT_ID}-input-invoices \
  --trigger-event=google.storage.object.finalize

print_status "Deploying 'geocode-addresses' function..."
gcloud functions deploy geocode-addresses \
  --no-gen2 \
  --region=${CLOUD_FUNCTION_LOCATION} \
  --entry-point=process_address \
  --runtime=python39 \
  --source=cloud-functions/geocode-addresses \
  --timeout=60 \
  --env-vars-file=cloud-functions/geocode-addresses/.env.yaml \
  --trigger-topic=${GEO_CODE_REQUEST_PUBSUB_TOPIC}

# --------------------------------------------------------------
# TASK 6: Manual UI Configuration (Cannot be automated)
# --------------------------------------------------------------
print_warning "-----------------------------------------------------------"
print_warning "MANUAL STEP REQUIRED (Task 6):"
print_warning "1. Go to Cloud Run functions console."
print_warning "2. Edit 'process-invoices' and 'geocode-addresses'."
print_warning "3. Update PROCESSOR_ID, PARSER_LOCATION, and API_KEY in the UI."
print_warning "   (The script cannot fetch your Processor ID or API Key for you)."
print_warning "-----------------------------------------------------------"
read -p "Press [Enter] once you have updated the Environment Variables in the UI..."

# --------------------------------------------------------------
# TASK 7: Upload Test Files
# --------------------------------------------------------------
print_status "Task 7: Uploading test invoices to trigger the pipeline..."
gsutil cp gs://spls/gsp927/documentai-pipeline-demo/sample-files/* gs://${PROJECT_ID}-input-invoices/

print_status "Upload complete!"
print_warning "-----------------------------------------------------------"
print_warning "VALIDATION:"
print_warning "1. Go to BigQuery -> invoice_parser_results -> doc_ai_extracted_entities"
print_warning "2. Click 'Preview' to see the extracted data."
print_warning "3. Check 'geocode_details' table for lat/lng data."
print_warning "-----------------------------------------------------------"
