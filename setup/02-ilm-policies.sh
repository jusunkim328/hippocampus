#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

ES_URL="${ES_URL:?ES_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"
ILM_DIR="${SCRIPT_DIR}/../ilm"

create_ilm_policy() {
  local policy_name="$1"
  local json_file="$2"

  echo -n "Creating ILM policy: ${policy_name} ... "
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${ES_URL}/_ilm/policy/${policy_name}" \
    -H "Content-Type: application/json" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    -d @"${json_file}")

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "OK ($http_code)"
  else
    echo "FAILED ($http_code)"
    curl -s -X PUT "${ES_URL}/_ilm/policy/${policy_name}" \
      -H "Content-Type: application/json" \
      -H "Authorization: ApiKey ${ES_API_KEY}" \
      -d @"${json_file}"
    echo ""
    return 1
  fi
}

echo "=== Hippocampus ILM Policy Setup ==="
echo "ES_URL: ${ES_URL}"
echo ""

ERRORS=0

create_ilm_policy "hippocampus-episodic"   "${ILM_DIR}/hippocampus-episodic.json"   || ((ERRORS++))
create_ilm_policy "hippocampus-accesslog"  "${ILM_DIR}/hippocampus-accesslog.json"  || ((ERRORS++))

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "Completed with ${ERRORS} error(s)."
  exit 1
else
  echo "All ILM policies created successfully."
fi
