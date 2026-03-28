#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Configuration
PROCESSOR_DISPLAY_NAME="${PROCESSOR_DISPLAY_NAME:-form-parser}"
PROCESSOR_TYPE="${PROCESSOR_TYPE:-FORM_PARSER_PROCESSOR}"
SA_NAME="${SA_NAME:-document-ai-service-account}"
VM_NAME="${VM_NAME:-document-ai-dev}"
LOCAL_FORM_URL="${LOCAL_FORM_URL:-https://storage.googleapis.com/spls/gsp924/form.pdf}"
VM_FORM_GCS="${VM_FORM_GCS:-gs://spls/gsp924/health-intake-form.pdf}"
LAB_SCRIPT_GCS="${LAB_SCRIPT_GCS:-gs://spls/gsp924/synchronous_doc_ai.py}"
# ------------------------------------------------------------------------------

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

json_value() {
  python3 -c "import json,sys; payload=json.load(sys.stdin); print(payload.get(sys.argv[1],''))" "$1"
}

processor_name_from_list() {
  python3 -c "
import json,sys
wanted=sys.argv[1]
payload=json.load(sys.stdin)
for item in payload.get('processors',[]):
    if item.get('displayName')==wanted:
        print(item.get('name',''))
        break
" "$1"
}

wait_for_role_binding() {
    local project_id="$1"
    local sa_email="$2"
    local role="$3"
    local max_attempts=24
    local attempt=1
    local iam_member="serviceAccount:${sa_email}"
    while (( attempt <= max_attempts )); do
        if gcloud projects get-iam-policy "$project_id" --format=json | python3 -c '
import json
import sys
payload = json.load(sys.stdin)
member = sys.argv[1]
role = sys.argv[2]
for binding in payload.get("bindings", []):
    if binding.get("role") == role and member in binding.get("members",[]):
        exit(0)
exit(1)
' "$iam_member" "$role" >/dev/null; then
            log "IAM binding for $role is now visible"
            return 0
        fi
        log "Waiting for IAM binding propagation ($attempt/$max_attempts)"
        sleep 5
        attempt=$((attempt + 1))
    done
    return 1
}

wait_for_service_account_api_access() {
  local sa_email="$1"
  local key_file="$2"
  local max_attempts=30
  local attempt=1
  while (( attempt <= max_attempts )); do
    if GOOGLE_APPLICATION_CREDENTIALS="$key_file" gcloud auth print-access-token | \
         curl -fsSL -H "Authorization: Bearer $(cat)" \
         "https://us-documentai.googleapis.com/v1beta3/projects/${PROJECT_ID}/locations/us/processors/${PROCESSOR_ID}" > /dev/null 2>&1; then
      log "Service account $sa_email can access the processor."
      return 0
    fi
    log "Waiting for service account permissions... ($attempt/$max_attempts)"
    sleep 5
    attempt=$((attempt + 1))
  done
  return 1
}

create_processor() {
  local token="$1"
  local url="https://us-documentai.googleapis.com/v1beta3/projects/${PROJECT_ID}/locations/us/processors"

  created="$(curl -fsSL -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"displayName\":\"${PROCESSOR_DISPLAY_NAME}\",\"type\":\"${PROCESSOR_TYPE}\"}" \
    "$url" | jq -r '.name')"

  if [[ -n "$created" ]]; then
    printf "%s\n" "$created"
    return 0
  fi

  curl -fsSL -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"displayName\":\"${PROCESSOR_DISPLAY_NAME}\"}" \
    "$url?processorType=${PROCESSOR_TYPE}" | jq -r '.name'
}

# ------------------------------------------------------------------------------
# Create the runner script that will execute on the VM
create_remote_runner() {
cat <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[remote %s] %s\n' "$(date +%H:%M:%S)" "$*"
}

retry() {
  local max_attempts="$1"
  local wait_seconds="$2"
  shift 2
  local attempt=1
  until "$@"; do
    local code=$?
    if (( attempt >= max_attempts )); then
      return "$code"
    fi
    log "Attempt $attempt/$max_attempts failed; retrying in ${wait_seconds}s"
    sleep "$wait_seconds"
    attempt=$((attempt + 1))
  done
}

# ------------------------------------------------------------------------------
# Input validation
: "${PROJECT_ID:?PROJECT_ID is required}"
: "${PROCESSOR_ID:?PROCESSOR_ID is required}"
: "${VM_FORM_GCS:?VM_FORM_GCS is required}"
: "${LOCAL_FORM_URL:?LOCAL_FORM_URL is required}"
: "${LAB_SCRIPT_GCS:?LAB_SCRIPT_GCS is required}"

export GOOGLE_APPLICATION_CREDENTIALS="$PWD/key.json"

printf "Your processor ID is: %s\n" "$PROCESSOR_ID"
echo "Your processor ID is: $PROCESSOR_ID"

export PROJECT_ID=$(gcloud config get-value core/project)

# ------------------------------------------------------------------------------
# Download required files
log "Downloading sample form"
gsutil cp "$VM_FORM_GCS" .
curl -fsSL "$LOCAL_FORM_URL" -o form.pdf

if [[ ! -f health-intake-form.pdf ]]; then
  log "ERROR: health-intake-form.pdf not found"
  exit 1
fi
if [[ ! -f form.pdf ]]; then
  log "ERROR: form.pdf not found"
  exit 1
fi

# ------------------------------------------------------------------------------
# Build request.json for curl
log "Building request.json"
echo '{"inlineDocument": {"mimeType": "application/pdf","content": "' > temp.json
base64 health-intake-form.pdf >> temp.json
echo '"}}' >> temp.json
cat temp.json | tr -d \\n > request.json
log "Task 3 completed: request.json ready"

# ------------------------------------------------------------------------------
# Call synchronous endpoint via curl (Task 4)
log "Calling synchronous Document AI endpoint via curl"
submit_request() {
  curl -fsSL -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d @request.json \
    "https://us-documentai.googleapis.com/v1beta3/projects/${PROJECT_ID}/locations/us/processors/${PROCESSOR_ID}:process" \
    > output.json
}
retry 30 10 submit_request

# ------------------------------------------------------------------------------
# Clean up dpkg locks and configure packages
log "Cleaning up dpkg locks and pending configurations"
sudo systemctl stop unattended-upgrades || true
sudo killall apt apt-get dpkg 2>/dev/null || true
sudo rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*
sudo fuser -k /var/cache/debconf/config.dat 2>/dev/null || true
sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
sudo apt-get clean || true

# Disable man-db trigger by temporarily moving the mandb binary
log "Temporarily moving mandb to prevent hang"
if [ -f /usr/bin/mandb ]; then
  sudo mv /usr/bin/mandb /usr/bin/mandb.bak
elif [ -f /usr/sbin/mandb ]; then
  sudo mv /usr/sbin/mandb /usr/sbin/mandb.bak
fi

# Prevent man-db from being triggered via debconf (belt and suspenders)
echo "man-db man-db/auto-update boolean false" | sudo debconf-set-selections

# ------------------------------------------------------------------------------
# Install packages
log "Installing python3-pip and jq"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  python3-pip jq

# Restore mandb binary
log "Restoring mandb binary"
if [ -f /usr/bin/mandb.bak ]; then
  sudo mv /usr/bin/mandb.bak /usr/bin/mandb
elif [ -f /usr/sbin/mandb.bak ]; then
  sudo mv /usr/sbin/mandb.bak /usr/sbin/mandb
fi

# Finalize any remaining triggers (just in case)
log "Finalizing package configuration"
sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a

# ------------------------------------------------------------------------------
# Install Python libraries (user‑level to avoid sudo)
log "Installing Python client libraries"
pip3 install --user --upgrade google-cloud-documentai google-cloud-storage prettytable

# ------------------------------------------------------------------------------
# Extract text and form fields as required by the lab (for validation)
log "Extracting text (Task 4 validation)"
cat output.json | jq -r ".document.text"
cat output.json | jq -r ".document.pages[].formFields"

# ------------------------------------------------------------------------------
# Python client part (Task 5 & 6)
log "Downloading Python sample"
gsutil cp gs://spls/gsp924/synchronous_doc_ai.py .

# Run Python script (Task 6)
log "Running Python client"
export PROJECT_ID=$(gcloud config get-value core/project)
export GOOGLE_APPLICATION_CREDENTIALS="$PWD/key.json"

python3 synchronous_doc_ai.py \
  --project_id="$PROJECT_ID" \
  --processor_id="$PROCESSOR_ID" \
  --location=us \
  --file_name=health-intake-form.pdf | tee results.txt

if [[ $? -eq 0 ]]; then
  log "Python script completed successfully."
else
  log "Python script failed. Capturing stderr:"
  python3 synchronous_doc_ai.py \
    --project_id="$PROJECT_ID" \
    --processor_id="$PROCESSOR_ID" \
    --location=us \
    --file_name=health-intake-form.pdf 2>&1 | tee python_errors.log
  exit 1
fi

log "All tasks completed."
REMOTE
}

# ------------------------------------------------------------------------------
# Main execution
main() {
  need bash
  need gcloud
  need curl
  need gsutil
  need python3
  need jq

  PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value core/project 2>/dev/null || true)}"
  [[ -n "$PROJECT_ID" ]] || die "Run this script inside Cloud Shell after selecting the lab project"
  export PROJECT_ID

  log "Project: $PROJECT_ID"

  # Enable required APIs
  log "Enabling required APIs"
  gcloud services enable \
    documentai.googleapis.com \
    compute.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    serviceusage.googleapis.com \
    --project "$PROJECT_ID" \
    --quiet

  local token
  token="$(gcloud auth print-access-token)"

  # Find or create processor
  log "Checking for existing processor $PROCESSOR_DISPLAY_NAME"
  local processor_name
  processor_name="$(curl -fsSL \
    -H "Authorization: Bearer $token" \
    "https://us-documentai.googleapis.com/v1beta3/projects/${PROJECT_ID}/locations/us/processors" \
    | processor_name_from_list "$PROCESSOR_DISPLAY_NAME")"

  if [[ -z "$processor_name" ]]; then
    log "Creating processor $PROCESSOR_DISPLAY_NAME"
    processor_name="$(create_processor "$token")"
  fi

  [[ -n "$processor_name" ]] || die "Processor creation failed"
  local processor_id="${processor_name##*/}"
  log "Processor ID: $processor_id"

  export PROCESSOR_ID="$processor_id"

  # ----------------------------------------------------------------------------
  # Create service account (outside VM)
  local sa_email="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  log "Creating service account $SA_NAME (if needed)"
  if ! gcloud iam service-accounts describe "$sa_email" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$SA_NAME" --display-name "$SA_NAME"
    for i in {1..12}; do
      if gcloud iam service-accounts describe "$sa_email" >/dev/null 2>&1; then
        break
      fi
      sleep 3
    done
  else
    log "Service account already exists"
  fi

  log "Granting roles/documentai.apiUser to $sa_email"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$sa_email" \
    --role="roles/documentai.apiUser" \
    --quiet

  wait_for_role_binding "$PROJECT_ID" "$sa_email" "roles/documentai.apiUser" || {
    log "Warning: IAM binding may not be fully propagated yet"
  }

  log "Creating service account key"
  rm -f key.json
  gcloud iam service-accounts keys create key.json \
    --iam-account "$sa_email"

  export GOOGLE_APPLICATION_CREDENTIALS="$PWD/key.json"
  wait_for_service_account_api_access "$sa_email" "$PWD/key.json" || {
    log "ERROR: Service account cannot access Document AI API after retries"
    exit 1
  }

  # ----------------------------------------------------------------------------
  local zone
  zone="$(gcloud compute instances list --filter="name=($VM_NAME)" --format="value(zone.basename())" | head -n 1)"
  [[ -n "$zone" ]] || die "VM $VM_NAME not found"
  log "VM zone: $zone"

  log "Copying key.json to VM $VM_NAME"
  gcloud compute scp key.json "$VM_NAME:~/key.json" \
    --zone "$zone" \
    --quiet \
    --scp-flag="-o StrictHostKeyChecking=no" \
    --scp-flag="-o UserKnownHostsFile=/dev/null"

  log "Writing remote runner"
  create_remote_runner > /tmp/document_ai_lab_runner.sh
  chmod +x /tmp/document_ai_lab_runner.sh

  log "Copying runner to $VM_NAME"
  gcloud compute scp /tmp/document_ai_lab_runner.sh "$VM_NAME:~/document_ai_lab_runner.sh" \
    --zone "$zone" \
    --quiet \
    --scp-flag="-o StrictHostKeyChecking=no" \
    --scp-flag="-o UserKnownHostsFile=/dev/null"

  log "Executing on $VM_NAME"
  gcloud compute ssh "$VM_NAME" \
    --zone "$zone" \
    --quiet \
    --ssh-flag="-o StrictHostKeyChecking=no" \
    --ssh-flag="-o UserKnownHostsFile=/dev/null" \
    --command "PROJECT_ID='$PROJECT_ID' PROCESSOR_ID='$processor_id' VM_FORM_GCS='$VM_FORM_GCS' LOCAL_FORM_URL='$LOCAL_FORM_URL' LAB_SCRIPT_GCS='$LAB_SCRIPT_GCS' bash ~/document_ai_lab_runner.sh"

  log "All tasks completed successfully."
}

main "$@"
