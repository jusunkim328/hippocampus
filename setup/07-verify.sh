#!/usr/bin/env bash
set -euo pipefail

# Hippocampus Deployment Verification — A2A metadata + Converse API basic test
#
# Usage:
#   export $(cat .env | xargs)
#   bash setup/07-verify.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  export $(cat "$ENV_FILE" | xargs)
fi

KIBANA_URL="${KIBANA_URL:?KIBANA_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"

ERRORS=0

echo "=== Hippocampus Deployment Verification ==="
echo "KIBANA_URL: ${KIBANA_URL}"
echo ""

# ── 1. A2A metadata check ───────────────────────────────────────────────────
echo -n "[1/3] A2A metadata (hippocampus.json) ... "
A2A_RESP=$(curl -s "${KIBANA_URL}/api/agent_builder/a2a/hippocampus.json" \
  -H "Authorization: ApiKey ${ES_API_KEY}" \
  -H "kbn-xsrf: true")

if echo "$A2A_RESP" | jq -e '.name' >/dev/null 2>&1; then
  A2A_NAME=$(echo "$A2A_RESP" | jq -r '.name')
  echo "OK (name: ${A2A_NAME})"
  echo "  Full response:"
  echo "$A2A_RESP" | jq .
else
  echo "FAILED or NOT FOUND"
  echo "  Response: ${A2A_RESP}"
  ((ERRORS++))
fi
echo ""

# ── 2. Converse API basic test ──────────────────────────────────────────────
echo -n "[2/3] Converse API (basic hello) ... "
CONV_RESP=$(curl -s -X POST "${KIBANA_URL}/api/agent_builder/converse" \
  -H "Authorization: ApiKey ${ES_API_KEY}" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "hippocampus", "input": "Hello, what can you help with?"}')

CONV_CONTENT=$(echo "$CONV_RESP" | jq -r '.response.message // .content // empty' 2>/dev/null)
if [ -n "$CONV_CONTENT" ]; then
  echo "OK"
  echo "  Response (first 200 chars): ${CONV_CONTENT:0:200}"
else
  echo "FAILED"
  echo "  Response: $(echo "$CONV_RESP" | head -5)"
  ((ERRORS++))
fi
echo ""

# ── 3. Agent registration check ───────────────────────────────────────────────
echo -n "[3/3] Agent registration ... "
AGENT_RESP=$(curl -s "${KIBANA_URL}/api/agent_builder/agents/hippocampus" \
  -H "Authorization: ApiKey ${ES_API_KEY}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: Kibana")

if echo "$AGENT_RESP" | jq -e '.id' >/dev/null 2>&1; then
  AGENT_NAME=$(echo "$AGENT_RESP" | jq -r '.name')
  TOOL_COUNT=$(echo "$AGENT_RESP" | jq '.configuration.tools[0].tool_ids | length')
  echo "OK (name: ${AGENT_NAME}, tools: ${TOOL_COUNT})"
else
  echo "FAILED"
  echo "  Response: $(echo "$AGENT_RESP" | head -5)"
  ((ERRORS++))
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "=== Verification: ${ERRORS} check(s) failed ==="
  exit 1
else
  echo "=== Verification: All checks passed ==="
fi
