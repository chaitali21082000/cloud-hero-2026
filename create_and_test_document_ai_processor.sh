#!/bin/bash
set -e

# ==============================
# CONFIG
# ==============================
export LOCATION="us"
export PROJECT_ID=$(gcloud config get-value core/project)
export SA_NAME="document-ai-service-account"

# ==============================
# INSTALL DEPENDENCIES (ONCE)
# ==============================
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y jq python3-pip >/dev/null 2>&1

# ==============================
# ENABLE API (gcloud is fine here)
# ==============================
gcloud services enable documentai.googleapis.com --quiet

# ==============================
# CREATE SERVICE ACCOUNT (gcloud is best)
# ==============================
gcloud iam service-accounts create $SA_NAME \
  --display-name=$SA_NAME --quiet || true

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:$SA_NAME@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/documentai.apiUser" --quiet

# ==============================
# CREATE KEY
# ==============================
gcloud iam service-accounts keys create key.json \
  --iam-account $SA_NAME@${PROJECT_ID}.iam.gserviceaccount.com --quiet

export GOOGLE_APPLICATION_CREDENTIALS="$PWD/key.json"

# ==============================
# GET ACCESS TOKEN (ONLY ONCE 🔥)
# ==============================
ACCESS_TOKEN=$(gcloud auth print-access-token)

# ==============================
# CREATE PROCESSOR (FAST API ✅)
# ==============================
PROCESSOR_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  "https://${LOCATION}-documentai.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/processors" \
  -d '{
    "type": "FORM_PARSER_PROCESSOR",
    "displayName": "form-parser"
  }')

# Debug (optional)
echo "$PROCESSOR_RESPONSE" | jq .

# Step 2: Extract ID safely
PROCESSOR_ID=$(echo "$PROCESSOR_RESPONSE" | jq -r '.name' | awk -F'/' '{print $NF}')

echo "Processor ID: $PROCESSOR_ID"

# ==============================
# DOWNLOAD FILE (gsutil is fastest here)
# ==============================
gsutil cp -q gs://spls/gsp924/health-intake-form.pdf .

# ==============================
# PREP REQUEST (NO TEMP FILES 🔥)
# ==============================
BASE64_DOC=$(base64 -w 0 health-intake-form.pdf)

REQUEST_JSON=$(jq -n \
  --arg content "$BASE64_DOC" \
  '{
    inlineDocument: {
      mimeType: "application/pdf",
      content: $content
    }
  }')

# ==============================
# PROCESS DOCUMENT (FAST API)
# ==============================
RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$REQUEST_JSON" \
  "https://${LOCATION}-documentai.googleapis.com/v1beta3/projects/${PROJECT_ID}/locations/${LOCATION}/processors/${PROCESSOR_ID}:process")

echo "$RESPONSE" > output.json

# ==============================
# PARSE OUTPUT (OPTIMIZED)
# ==============================
echo "===== RAW TEXT ====="
echo "$RESPONSE" | jq -r ".document.text"

echo "===== FORM FIELDS ====="
echo "$RESPONSE" | jq -r ".document.pages[].formFields"

# ==============================
# PYTHON PART (OPTIONAL)
# ==============================
gsutil cp -q gs://spls/gsp924/synchronous_doc_ai.py .

python3 -m pip install --quiet --upgrade \
  google-cloud-documentai google-cloud-storage prettytable

python3 synchronous_doc_ai.py \
  --project_id=$PROJECT_ID \
  --processor_id=$PROCESSOR_ID \
  --location=$LOCATION \
  --file_name=health-intake-form.pdf | tee results.txt

echo "✅ FULL LAB COMPLETED (OPTIMIZED)"
