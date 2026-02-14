#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="${SCRIPT_DIR}/../tools"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

KIBANA_URL="${KIBANA_URL:?KIBANA_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"

register_tool() {
  local tool_file="$1"
  local tool_id
  tool_id=$(python3 -c "import json; print(json.load(open('$tool_file'))['id'])")

  echo -n "Registering tool: ${tool_id} ... "

  local http_code
  http_code=$(curl -s -o /tmp/tool_response.json -w "%{http_code}" \
    -X POST "${KIBANA_URL}/api/agent_builder/tools" \
    -H "Content-Type: application/json" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    -H "kbn-xsrf: true" \
    -d @"${tool_file}")

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "OK ($http_code)"
  elif [ "$http_code" -eq 409 ]; then
    echo "ALREADY EXISTS ($http_code) — skipped"
  else
    echo "FAILED ($http_code)"
    python3 -c "import json; d=json.load(open('/tmp/tool_response.json')); print('  Error:', json.dumps(d, indent=2, ensure_ascii=False)[:300])" 2>/dev/null || true
    return 1
  fi
}

echo "=== Hippocampus Tool Registration ==="
echo "Kibana: ${KIBANA_URL}"
echo ""

ERRORS=0

register_tool "${TOOLS_DIR}/recall.json"             || ((ERRORS++))
register_tool "${TOOLS_DIR}/contradict.json"          || ((ERRORS++))
register_tool "${TOOLS_DIR}/blindspot-density.json"   || ((ERRORS++))
register_tool "${TOOLS_DIR}/blindspot-targeted.json"  || ((ERRORS++))
register_tool "${TOOLS_DIR}/remember.json"            || ((ERRORS++))

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "Completed with ${ERRORS} error(s)."
  exit 1
else
  echo "All 5 tools registered successfully."
fi
