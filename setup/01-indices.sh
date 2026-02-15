#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

ES_URL="${ES_URL:?ES_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"
INDICES_DIR="${SCRIPT_DIR}/../indices"

create_index() {
  local index_name="$1"
  local json_file="$2"

  echo -n "Creating index: ${index_name} ... "
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${ES_URL}/${index_name}" \
    -H "Content-Type: application/json" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    -d @"${json_file}")

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "OK ($http_code)"
  elif [ "$http_code" -eq 400 ]; then
    # ES returns 400 resource_already_exists_exception for existing indices
    echo "ALREADY EXISTS ($http_code) — skipped"
  else
    echo "FAILED ($http_code)"
    curl -s -X PUT "${ES_URL}/${index_name}" \
      -H "Content-Type: application/json" \
      -H "Authorization: ApiKey ${ES_API_KEY}" \
      -d @"${json_file}"
    echo ""
    return 1
  fi
}

echo "=== Hippocampus Index Setup ==="
echo "ES_URL: ${ES_URL}"
echo ""

ERRORS=0

create_index "episodic-memories"    "${INDICES_DIR}/episodic-memories.json"    || ((ERRORS++))
create_index "semantic-memories"    "${INDICES_DIR}/semantic-memories.json"    || ((ERRORS++))
create_index "memory-associations"  "${INDICES_DIR}/memory-associations.json"  || ((ERRORS++))
create_index "memory-access-log"    "${INDICES_DIR}/memory-access-log.json"    || ((ERRORS++))
create_index "knowledge-domains"    "${INDICES_DIR}/knowledge-domains.json"    || ((ERRORS++))
create_index "knowledge-domains-staging" "${INDICES_DIR}/knowledge-domains-staging.json" || ((ERRORS++))

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "Completed with ${ERRORS} error(s)."
  exit 1
else
  echo "All 6 indices created successfully."
fi
