#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${SCRIPT_DIR}/../agent"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

KIBANA_URL="${KIBANA_URL:?KIBANA_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"

AGENT_FILE="${AGENT_DIR}/hippocampus-agent.json"

echo "=== Hippocampus Agent Registration ==="
echo "Kibana: ${KIBANA_URL}"
echo ""

if [ ! -f "$AGENT_FILE" ]; then
  echo "ERROR: Agent file not found: $AGENT_FILE"
  exit 1
fi

AGENT_NAME=$(python3 -c "import json; print(json.load(open('$AGENT_FILE'))['name'])")
echo -n "Registering agent: ${AGENT_NAME} ... "

http_code=$(curl -s -o /tmp/agent_response.json -w "%{http_code}" \
  -X POST "${KIBANA_URL}/api/agent_builder/agents" \
  -H "Content-Type: application/json" \
  -H "Authorization: ApiKey ${ES_API_KEY}" \
  -H "kbn-xsrf: true" \
  -d @"${AGENT_FILE}")

if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
  echo "OK ($http_code)"
elif [ "$http_code" -eq 400 ] || [ "$http_code" -eq 409 ]; then
  echo "ALREADY EXISTS ($http_code) — skipped"
else
  echo "FAILED ($http_code)"
  python3 -c "import json; d=json.load(open('/tmp/agent_response.json')); print('  Error:', json.dumps(d, indent=2, ensure_ascii=False)[:500])" 2>/dev/null || true
  exit 1
fi

echo ""
echo "=== Registration Complete ==="
echo "Agent '${AGENT_NAME}' registered successfully."
echo "Open Kibana to chat: ${KIBANA_URL}/app/agent_builder"
