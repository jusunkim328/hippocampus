#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# 04-mcp-remember.sh
#
# hippocampus-remember 도구를 MCP 기반으로 등록합니다.
#
# 배경: Elastic Workflows (Technical Preview) 실행 엔진이 동작하지 않아
#       workflow 타입 → mcp 타입으로 전환.
#       MCP 서버(mcp-server/)가 ES REST API로 직접 3개 인덱스에 쓰기 수행.
#
# 사전 요구사항:
#   - MCP 서버가 배포되어 HTTPS URL로 접근 가능해야 함
#   - .env에 MCP_SERVER_URL 설정 필요
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

echo "=== Hippocampus Remember Tool (MCP) ==="
echo "Kibana:     ${KIBANA_URL}"
echo "MCP Server: ${MCP_SERVER_URL}"
echo ""

# ─── Step 1: 기존 workflow 기반 remember 도구 삭제 (있으면) ───
echo -n "Removing old remember tool (if exists) ... "
old_http=$(curl -s -o /dev/null -w "%{http_code}" \
  -X DELETE "${KIBANA_URL}/api/agent_builder/tools/hippocampus-remember" \
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

# ─── Step 2: .mcp 커넥터 생성 (idempotent) ───
echo -n "Creating MCP connector ... "
CONNECTOR_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "${KIBANA_URL}/api/actions/connector" \
  -H "Content-Type: application/json" \
  -H "Authorization: ApiKey ${ES_API_KEY}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: Kibana" \
  -d "$(python3 -c "
import json
print(json.dumps({
    'connector_type_id': '.mcp',
    'name': 'hippocampus-memory-writer',
    'config': {
        'serverUrl': '${MCP_SERVER_URL}'
    },
    'secrets': {}
}))
")")

CONNECTOR_HTTP=$(echo "$CONNECTOR_RESPONSE" | tail -1)
CONNECTOR_BODY=$(echo "$CONNECTOR_RESPONSE" | head -n -1)

if [ "$CONNECTOR_HTTP" -ge 200 ] && [ "$CONNECTOR_HTTP" -lt 300 ]; then
  CONNECTOR_ID=$(echo "$CONNECTOR_BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  echo "OK (id: ${CONNECTOR_ID})"
elif [ "$CONNECTOR_HTTP" -eq 409 ]; then
  # 이미 존재 — 기존 커넥터 조회
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

# ─── Step 3: MCP 기반 remember 도구 등록 ───
echo -n "Registering hippocampus-remember (MCP) ... "
TOOL_HTTP=$(curl -s -o /tmp/mcp_tool_response.json -w "%{http_code}" \
  -X POST "${KIBANA_URL}/api/agent_builder/tools" \
  -H "Content-Type: application/json" \
  -H "Authorization: ApiKey ${ES_API_KEY}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: Kibana" \
  -d "$(python3 -c "
import json
print(json.dumps({
    'id': 'hippocampus-remember',
    'type': 'mcp',
    'description': '새로운 경험을 조직 지식으로 저장합니다. 대화에서 핵심 사실을 SPO 트리플로 구조화하고 episodic-memories와 semantic-memories에 기록합니다. 저장 전 Contradict 도구로 기존 지식과의 모순 여부를 자동 검증합니다.',
    'tags': ['hippocampus', 'memory', 'remember'],
    'configuration': {
        'connector_id': '${CONNECTOR_ID}',
        'tool_name': 'remember_memory'
    }
}, ensure_ascii=False))
")")

if [ "$TOOL_HTTP" -ge 200 ] && [ "$TOOL_HTTP" -lt 300 ]; then
  echo "OK ($TOOL_HTTP)"
elif [ "$TOOL_HTTP" -eq 400 ] || [ "$TOOL_HTTP" -eq 409 ]; then
  echo "ALREADY EXISTS ($TOOL_HTTP) — skipped"
else
  echo "FAILED ($TOOL_HTTP)"
  python3 -c "import json; d=json.load(open('/tmp/mcp_tool_response.json')); print('  Error:', json.dumps(d, indent=2, ensure_ascii=False)[:300])" 2>/dev/null || true
  exit 1
fi

echo ""
echo "Done! hippocampus-remember is now MCP-based."
echo "  Connector: ${CONNECTOR_ID} → ${MCP_SERVER_URL}"
echo "  Tool:      hippocampus-remember (type: mcp, tool: remember_memory)"
