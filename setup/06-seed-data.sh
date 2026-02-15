#!/bin/bash
set -euo pipefail

# Hippocampus - Seed Data Loader
# Loads NDJSON seed data into Elasticsearch via Bulk API

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_DIR="${SCRIPT_DIR}/../seed-data"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

ES_URL="${ES_URL:?ES_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"

load_ndjson() {
  local file="$1"
  local name
  name="$(basename "$file")"

  if [ ! -f "$file" ]; then
    echo "[ERROR] File not found: $file"
    return 1
  fi

  echo -n "[INFO] Loading ${name} ... "

  local http_code
  http_code=$(curl -s -o /tmp/bulk_response.json -w "%{http_code}" \
    -X POST "${ES_URL}/_bulk" \
    -H "Content-Type: application/x-ndjson" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    --data-binary "@${file}")

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    if grep -q '"errors":false' /tmp/bulk_response.json 2>/dev/null; then
      echo "OK ($http_code)"
    else
      echo "OK with warnings ($http_code)"
    fi
  else
    echo "FAILED ($http_code)"
    cat /tmp/bulk_response.json | head -5
    return 1
  fi
}

echo "============================================"
echo " Hippocampus Seed Data Loader"
echo " Target: ${ES_URL}"
echo "============================================"
echo ""

load_ndjson "${SEED_DIR}/episodic-memories.ndjson"
load_ndjson "${SEED_DIR}/semantic-memories.ndjson"
load_ndjson "${SEED_DIR}/knowledge-domains.ndjson"

echo ""
echo "============================================"
echo " Seed data loading complete"
echo "============================================"
