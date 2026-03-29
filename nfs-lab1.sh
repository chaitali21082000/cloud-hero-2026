#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Configuration (same as original)
PROCESSOR_DISPLAY_NAME="${PROCESSOR_DISPLAY_NAME:-form-parser}"
PROCESSOR_TYPE="${PROCESSOR_TYPE:-FORM_PARSER_PROCESSOR}"
SA_NAME="${SA_NAME:-document-ai-service-account}"
VM_NAME="${VM_NAME:-document-ai-dev}"
LOCAL_FORM_URL="${LOCAL_FORM_URL:-https://storage.googleapis.com/spls/gsp924/form.pdf}"
VM_FORM_GCS="${VM_FORM_GCS:-gs://spls/gsp924/health-intake-form.pdf}"
LAB_SCRIPT_GCS="${LAB_SCRIPT_GCS:-gs://spls/gsp924/synchronous_doc_ai.py}"
# ------------------------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

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
    local project_id="$1" sa_email="$2" role="$3"
    local iam_member="serviceAccount:${sa_email}"
    for attempt in {1..12}; do
        if gcloud projects get-iam-policy "$project_id" --format=json | python3 -c '
import json,sys
payload = json.load(sys.stdin)
member = sys.argv[1]
role = sys.argv[2]
for binding in payload.get("bindings", []):
    if binding.get("role") == role and member in binding.get("members",[]):
        exit(0)
exit(1)
' "$iam_member" "$role" >/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_for_service_account_api_access() {
  local sa_email="$1" key_file="$2"
  for attempt in {1..20}; do
    if GOOGLE_APPLICATION_CREDENTIALS="$key_file" gcloud auth print-access-token | \
         curl -fsSL -H "Authorization: Bearer $(cat)" \
         "https://us-documentai.googleapis.com/v1beta3/projects/${PROJECT_ID}/locations/us/processors/${PROCESSOR_ID}" > /dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

create_processor() {
  local token="$1"
  local url="https://us-documentai.googleapis.com/v1beta3/projects/${PROJECT_ID}/locations/us/processors"
  created="$(curl -fsSL -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"displayName\":\"${PROCESSOR_DISPLAY_NAME}\",\"type\":\"${PROCESSOR_TYPE}\"}" "$url" | jq -r '.name')"
  if [[ -n "$created" ]]; then echo "$created"; return 0; fi
  curl -fsSL -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json; charset=utf-8" \
    -d "{\"displayName\":\"${PROCESSOR_DISPLAY_NAME}\"}" "$url?processorType=${PROCESSOR_TYPE}" | jq -r '.name'
}

# ------------------------------------------------------------------------------
# Remote runner script (optimised)
create_remote_runner() {
cat <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
log() { printf '[remote %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
retry() { local max="$1" wait="$2"; shift 2; for ((i=1;i<=max;i++)); do "$@" && return 0; sleep "$wait"; done; return 1; }

: "${PROJECT_ID:?PROJECT_ID is required}" "${PROCESSOR_ID:?PROCESSOR_ID is required}"
export GOOGLE_APPLICATION_CREDENTIALS="$PWD/key.json"

echo "Your processor ID is: $PROCESSOR_ID"

# Download files
gsutil cp "$VM_FORM_GCS" .
curl -fsSL "$LOCAL_FORM_URL" -o form.pdf
[[ -f health-intake-form.pdf && -f form.pdf ]] || exit 1

# Build request.json for Task 3
echo '{"inlineDocument": {"mimeType": "application/pdf","content": "' > temp.json
base64 health-intake-form.pdf >> temp.json
echo '"}}' >> temp.json
cat temp.json | tr -d \\n > request.json
log "Task 3 completed: request.json ready"

# Task 4 - curl call
log "Calling synchronous endpoint"
retry 10 5 curl -fsSL -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json; charset=utf-8" -d @request.json \
  "https://us-documentai.googleapis.com/v1beta3/projects/${PROJECT_ID}/locations/us/processors/${PROCESSOR_ID}:process" > output.json

# Clean up dpkg locks (fast)
sudo systemctl stop unattended-upgrades 2>/dev/null || true
sudo killall apt apt-get dpkg 2>/dev/null || true
sudo rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null || true
sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true

# Disable mandb to avoid hang
if [ -f /usr/bin/mandb ]; then sudo mv /usr/bin/mandb /usr/bin/mandb.bak; elif [ -f /usr/sbin/mandb ]; then sudo mv /usr/sbin/mandb /usr/sbin/mandb.bak; fi
echo "man-db man-db/auto-update boolean false" | sudo debconf-set-selections

# Install packages in one go
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" python3-pip jq

# Restore mandb
if [ -f /usr/bin/mandb.bak ]; then sudo mv /usr/bin/mandb.bak /usr/bin/mandb; elif [ -f /usr/sbin/mandb.bak ]; then sudo mv /usr/sbin/mandb.bak /usr/sbin/mandb; fi
sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a

# Install Python libraries
pip3 install --user --upgrade google-cloud-documentai google-cloud-storage prettytable

# Extract text and form fields for validation (Task 4)
cat output.json | jq -r ".document.text"
cat output.json | jq -r ".document.pages[].formFields"

# Task 5 & 6 - Python client
gsutil cp gs://spls/gsp924/synchronous_doc_ai.py .
export PROJECT_ID=$(gcloud config get-value core/project)

for attempt in {1..5}; do
  if python3 synchronous_doc_ai.py --project_id="$PROJECT_ID" --processor_id="$PROCESSOR_ID" --location=us --file_name=health-intake-form.pdf | tee results.txt; then
    log "Python script succeeded"
    break
  else
    [ $attempt -eq 5 ] && exit 1
    sleep $((2**attempt))
  fi
done

log "All tasks completed."
REMOTE
}

# ------------------------------------------------------------------------------
# Main execution
main() {
  need bash gcloud curl gsutil python3 jq
  PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value core/project 2>/dev/null || true)}"
  [[ -n "$PROJECT_ID" ]] || die "Run this script inside Cloud Shell after selecting the lab project"
  export PROJECT_ID

  log "Project: $PROJECT_ID"

  # Enable APIs (quiet)
  gcloud services enable documentai.googleapis.com compute.googleapis.com iam.googleapis.com iamcredentials.googleapis.com serviceusage.googleapis.com --project "$PROJECT_ID" --quiet

  local token="$(gcloud auth print-access-token)"

  # Find or create processor
  local processor_name="$(curl -fsSL -H "Authorization: Bearer $token" \
    "https://us-documentai.googleapis.com/v1beta3/projects/${PROJECT_ID}/locations/us/processors" \
    | processor_name_from_list "$PROCESSOR_DISPLAY_NAME")"
  if [[ -z "$processor_name" ]]; then
    processor_name="$(create_processor "$token")"
  fi
  [[ -n "$processor_name" ]] || die "Processor creation failed"
  local processor_id="${processor_name##*/}"
  log "Processor ID: $processor_id"
  export PROCESSOR_ID="$processor_id"

  # Service account
  local sa_email="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  if ! gcloud iam service-accounts describe "$sa_email" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$SA_NAME" --display-name "$SA_NAME"
    for i in {1..5}; do gcloud iam service-accounts describe "$sa_email" >/dev/null 2>&1 && break || sleep 2; done
  fi

  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$sa_email" --role="roles/documentai.apiUser" --quiet
  wait_for_role_binding "$PROJECT_ID" "$sa_email" "roles/documentai.apiUser"

  rm -f key.json
  gcloud iam service-accounts keys create key.json --iam-account "$sa_email"
  export GOOGLE_APPLICATION_CREDENTIALS="$PWD/key.json"
  wait_for_service_account_api_access "$sa_email" "$PWD/key.json" || die "Service account cannot access API"

  local zone="$(gcloud compute instances list --filter="name=($VM_NAME)" --format="value(zone.basename())" | head -n 1)"
  [[ -n "$zone" ]] || die "VM $VM_NAME not found"

  gcloud compute scp key.json "$VM_NAME:~/key.json" --zone "$zone" --quiet --scp-flag="-o StrictHostKeyChecking=no" --scp-flag="-o UserKnownHostsFile=/dev/null"

  create_remote_runner > /tmp/document_ai_lab_runner.sh
  chmod +x /tmp/document_ai_lab_runner.sh
  gcloud compute scp /tmp/document_ai_lab_runner.sh "$VM_NAME:~/document_ai_lab_runner.sh" --zone "$zone" --quiet --scp-flag="-o StrictHostKeyChecking=no" --scp-flag="-o UserKnownHostsFile=/dev/null"

  gcloud compute ssh "$VM_NAME" --zone "$zone" --quiet --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" \
    --command "PROJECT_ID='$PROJECT_ID' PROCESSOR_ID='$processor_id' VM_FORM_GCS='$VM_FORM_GCS' LOCAL_FORM_URL='$LOCAL_FORM_URL' LAB_SCRIPT_GCS='$LAB_SCRIPT_GCS' bash ~/document_ai_lab_runner.sh"

  log "All tasks completed successfully."
}

main "$@"
