#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKFLOWS_DIR="${SCRIPT_DIR}/../workflows"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

KIBANA_URL="${KIBANA_URL:?KIBANA_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"

register_workflow() {
  local workflow_file="$1"
  local workflow_name
  workflow_name=$(basename "$workflow_file" .yaml)

  echo -n "Registering workflow: ${workflow_name} ... "

  # Read YAML content and wrap in JSON
  local yaml_content
  yaml_content=$(cat "$workflow_file")

  local http_code
  http_code=$(curl -s -o /tmp/workflow_response.json -w "%{http_code}" \
    -X POST "${KIBANA_URL}/api/workflows" \
    -H "Content-Type: application/json" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana" \
    --data-raw "$(python3 -c "import json; print(json.dumps({'yaml': open('$workflow_file').read()}))")")

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "OK ($http_code)"
  elif [ "$http_code" -eq 400 ] || [ "$http_code" -eq 409 ]; then
    echo "ALREADY EXISTS ($http_code) — skipped"
  else
    echo "FAILED ($http_code)"
    python3 -c "import json; d=json.load(open('/tmp/workflow_response.json')); print('  Error:', json.dumps(d, indent=2, ensure_ascii=False)[:300])" 2>/dev/null || true
    return 1
  fi
}

echo "=== Hippocampus Workflow Registration ==="
echo "Kibana: ${KIBANA_URL}"
echo ""

ERRORS=0

register_workflow "${WORKFLOWS_DIR}/remember-memory.yaml"       || ((ERRORS++))
register_workflow "${WORKFLOWS_DIR}/reflect-consolidate.yaml"   || ((ERRORS++))
register_workflow "${WORKFLOWS_DIR}/blindspot-report.yaml"      || ((ERRORS++))

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "Completed with ${ERRORS} error(s)."
  exit 1
else
  echo "All 3 workflows registered successfully."
fi
