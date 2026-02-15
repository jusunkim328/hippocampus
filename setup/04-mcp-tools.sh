#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# 04-mcp-tools.sh
#
# Registers 5 MCP-based tools:
#   - hippocampus-remember: Store experience
#   - hippocampus-reflect: Episode consolidation
#   - hippocampus-blindspot-report: Blindspot report
#   - hippocampus-export: Knowledge base NDJSON export
#   - hippocampus-import: Knowledge base NDJSON import
#
# Background: Elastic Workflows (Technical Preview) execution engine does not work,
#             so workflow type was switched to mcp type.
#             MCP server (mcp-server/) performs direct index read/write via ES REST API.
#
# Prerequisites:
#   - MCP server must be deployed and accessible via HTTPS URL
#   - MCP_SERVER_URL must be set in .env
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

KIBANA_URL="${KIBANA_URL:?KIBANA_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"
MCP_SERVER_URL="${MCP_SERVER_URL:?MCP_SERVER_URL is required. Set it in .env (e.g. https://your-mcp-server.run.app/mcp)}"

echo "=== Hippocampus MCP Tools (5 tools) ==="
echo "Kibana:     ${KIBANA_URL}"
echo "MCP Server: ${MCP_SERVER_URL}"
echo ""

# ─── Step 1: Remove existing MCP tools (if any) ───
for tool_id in hippocampus-remember hippocampus-reflect hippocampus-blindspot-report hippocampus-export hippocampus-import; do
  echo -n "Removing old tool ${tool_id} (if exists) ... "
  old_http=$(curl -s -o /dev/null -w "%{http_code}" \
    -X DELETE "${KIBANA_URL}/api/agent_builder/tools/${tool_id}" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana")

  if [ "$old_http" -eq 200 ]; then
    echo "REMOVED"
  elif [ "$old_http" -eq 404 ]; then
    echo "NOT FOUND (ok)"
  else
    echo "HTTP $old_http (continuing)"
  fi
done

# ─── Step 2: Create .mcp connector (idempotent) ───
echo -n "Creating MCP connector ... "

# Generate JSON to file to avoid shell quoting issues
python3 -c "
import json, os
print(json.dumps({
    'connector_type_id': '.mcp',
    'name': 'hippocampus-memory-writer',
    'config': {
        'serverUrl': os.environ['MCP_SERVER_URL']
    },
    'secrets': {}
}))" > /tmp/mcp_connector.json

CONNECTOR_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "${KIBANA_URL}/api/actions/connector" \
  -H "Content-Type: application/json" \
  -H "Authorization: ApiKey ${ES_API_KEY}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: Kibana" \
  -d @/tmp/mcp_connector.json)

CONNECTOR_HTTP=$(echo "$CONNECTOR_RESPONSE" | tail -1)
CONNECTOR_BODY=$(echo "$CONNECTOR_RESPONSE" | sed '$d')

if [ "$CONNECTOR_HTTP" -ge 200 ] && [ "$CONNECTOR_HTTP" -lt 300 ]; then
  CONNECTOR_ID=$(echo "$CONNECTOR_BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  echo "OK (id: ${CONNECTOR_ID})"
elif [ "$CONNECTOR_HTTP" -eq 409 ]; then
  # Already exists — find existing connector
  echo "ALREADY EXISTS — finding existing..."
  CONNECTOR_ID=$(curl -s "${KIBANA_URL}/api/actions/connectors" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana" \
    | python3 -c "
import json, sys
connectors = json.load(sys.stdin)
for c in connectors:
    if c.get('name') == 'hippocampus-memory-writer' and c.get('connector_type_id') == '.mcp':
        print(c['id'])
        break
")
  echo "  Found connector: ${CONNECTOR_ID}"
else
  echo "FAILED (HTTP ${CONNECTOR_HTTP})"
  echo "$CONNECTOR_BODY" | python3 -m json.tool 2>/dev/null || echo "$CONNECTOR_BODY"
  exit 1
fi

# ─── Step 3: Register 5 MCP tools ───

register_tool() {
  local TOOL_ID="$1"
  local TOOL_NAME="$2"
  local TOOL_DESC="$3"

  echo -n "Registering ${TOOL_ID} (MCP: ${TOOL_NAME}) ... "

  # Generate JSON to file to avoid shell quoting issues
  python3 -c "
import json, os
print(json.dumps({
    'id': os.environ['_TOOL_ID'],
    'type': 'mcp',
    'description': os.environ['_TOOL_DESC'],
    'tags': ['hippocampus', 'memory'],
    'configuration': {
        'connector_id': os.environ['_CONNECTOR_ID'],
        'tool_name': os.environ['_TOOL_NAME']
    }
}, ensure_ascii=False))" > /tmp/mcp_tool_payload.json

  TOOL_HTTP=$(curl -s -o /tmp/mcp_tool_response.json -w "%{http_code}" \
    -X POST "${KIBANA_URL}/api/agent_builder/tools" \
    -H "Content-Type: application/json" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana" \
    -d @/tmp/mcp_tool_payload.json)

  if [ "$TOOL_HTTP" -ge 200 ] && [ "$TOOL_HTTP" -lt 300 ]; then
    echo "OK ($TOOL_HTTP)"
  elif [ "$TOOL_HTTP" -eq 400 ] || [ "$TOOL_HTTP" -eq 409 ]; then
    echo "ALREADY EXISTS ($TOOL_HTTP) — skipped"
  else
    echo "FAILED ($TOOL_HTTP)"
    python3 -c "import json; d=json.load(open('/tmp/mcp_tool_response.json')); print('  Error:', json.dumps(d, indent=2, ensure_ascii=False)[:300])" 2>/dev/null || true
    exit 1
  fi
}

export _CONNECTOR_ID="${CONNECTOR_ID}"

_TOOL_ID="hippocampus-remember" \
_TOOL_NAME="remember_memory" \
_TOOL_DESC="Store new organizational experience as knowledge. Use after incident resolution or when user requests to save. Structures key facts as SPO triples (entity/attribute/value) and records in 3 indices. MUST display Experience Grade after saving." \
  register_tool "hippocampus-remember" "remember_memory" ""

_TOOL_ID="hippocampus-reflect" \
_TOOL_NAME="reflect_consolidate" \
_TOOL_DESC="Consolidate episodic memories into semantic memory analysis. Use periodically or when user requests consolidation. Collects episodes with reflected=false, aggregates statistics by category, and updates domain density." \
  register_tool "hippocampus-reflect" "reflect_consolidate" ""

_TOOL_ID="hippocampus-blindspot-report" \
_TOOL_NAME="generate_blindspot_report" \
_TOOL_DESC="Generate a blindspot report for all knowledge domains. Use for status assessment or when user requests blindspot analysis. Reports domain-level knowledge density with VOID/SPARSE/DENSE/Stale classification." \
  register_tool "hippocampus-blindspot-report" "generate_blindspot_report" ""

_TOOL_ID="hippocampus-export" \
_TOOL_NAME="export_knowledge_base" \
_TOOL_DESC="Export the entire organizational knowledge base as NDJSON. Use for backup or cross-team knowledge sharing. Returns episodic/semantic/domain documents as NDJSON with _type tags." \
  register_tool "hippocampus-export" "export_knowledge_base" ""

_TOOL_ID="hippocampus-import" \
_TOOL_NAME="import_knowledge_base" \
_TOOL_DESC="Import a knowledge base from NDJSON format. Use to restore exported data to another environment or merge team knowledge. Marks semantic duplicates as CONFLICT." \
  register_tool "hippocampus-import" "import_knowledge_base" ""

echo ""
echo "Done! 5 MCP tools registered successfully."
echo "  Connector: ${CONNECTOR_ID} → ${MCP_SERVER_URL}"
echo "  Tools:"
echo "    - hippocampus-remember        (remember_memory)"
echo "    - hippocampus-reflect         (reflect_consolidate)"
echo "    - hippocampus-blindspot-report (generate_blindspot_report)"
echo "    - hippocampus-export          (export_knowledge_base)"
echo "    - hippocampus-import          (import_knowledge_base)"
