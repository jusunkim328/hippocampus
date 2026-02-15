#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# 04-mcp-tools.sh
#
# MCP 기반 도구 5개를 등록합니다:
#   - hippocampus-remember: 경험 저장
#   - hippocampus-reflect: 에피소드 통합
#   - hippocampus-blindspot-report: 사각지대 보고서
#   - hippocampus-export: 지식 베이스 NDJSON 내보내기
#   - hippocampus-import: 지식 베이스 NDJSON 가져오기
#
# 배경: Elastic Workflows (Technical Preview) 실행 엔진이 동작하지 않아
#       workflow 타입 → mcp 타입으로 전환.
#       MCP 서버(mcp-server/)가 ES REST API로 직접 인덱스에 쓰기/읽기 수행.
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

echo "=== Hippocampus MCP Tools (3개) ==="
echo "Kibana:     ${KIBANA_URL}"
echo "MCP Server: ${MCP_SERVER_URL}"
echo ""

# ─── Step 1: 기존 MCP 도구 삭제 (있으면) ───
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

# ─── Step 2: .mcp 커넥터 생성 (idempotent) ───
echo -n "Creating MCP connector ... "

# JSON을 파일로 생성하여 쉘 인용 문제 방지
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

# ─── Step 3: MCP 도구 3개 등록 ───

register_tool() {
  local TOOL_ID="$1"
  local TOOL_NAME="$2"
  local TOOL_DESC="$3"

  echo -n "Registering ${TOOL_ID} (MCP: ${TOOL_NAME}) ... "

  # JSON을 파일로 생성하여 쉘 인용 문제 방지
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
_TOOL_DESC="새로운 경험을 조직 지식으로 저장합니다. 인시던트 해결 후 또는 사용자가 저장을 요청할 때 사용합니다. 대화에서 핵심 사실을 SPO 트리플(entity/attribute/value)로 구조화하고 3개 인덱스에 기록합니다. 저장 완료 후 반드시 Experience Grade를 표시하세요." \
  register_tool "hippocampus-remember" "remember_memory" ""

_TOOL_ID="hippocampus-reflect" \
_TOOL_NAME="reflect_consolidate" \
_TOOL_DESC="에피소드 기억을 시맨틱 메모리로 통합 분석합니다. 주기적으로 호출하거나 사용자가 통합 분석을 요청할 때 사용합니다. reflected=false인 에피소드를 수집하여 카테고리별 통계를 집계하고 도메인 밀도를 갱신합니다." \
  register_tool "hippocampus-reflect" "reflect_consolidate" ""

_TOOL_ID="hippocampus-blindspot-report" \
_TOOL_NAME="generate_blindspot_report" \
_TOOL_DESC="전체 지식 도메인의 사각지대 보고서를 생성합니다. 현황 파악이 필요하거나 사용자가 사각지대 분석을 요청할 때 사용합니다. VOID/SPARSE/DENSE/Stale 분류로 도메인별 지식 밀도를 보고합니다." \
  register_tool "hippocampus-blindspot-report" "generate_blindspot_report" ""

_TOOL_ID="hippocampus-export" \
_TOOL_NAME="export_knowledge_base" \
_TOOL_DESC="조직의 전체 지식 베이스를 NDJSON 형식으로 내보냅니다. 백업이나 팀 간 지식 공유에 사용합니다. episodic/semantic/domain 문서를 _type 태그 포함 NDJSON으로 반환합니다." \
  register_tool "hippocampus-export" "export_knowledge_base" ""

_TOOL_ID="hippocampus-import" \
_TOOL_NAME="import_knowledge_base" \
_TOOL_DESC="NDJSON 형식의 지식 베이스를 가져옵니다. export_knowledge_base로 내보낸 데이터를 다른 환경에 복원하거나 팀 지식을 병합할 때 사용합니다. semantic 중복 시 CONFLICT로 표시합니다." \
  register_tool "hippocampus-import" "import_knowledge_base" ""

echo ""
echo "Done! 5개 MCP 도구 등록 완료."
echo "  Connector: ${CONNECTOR_ID} → ${MCP_SERVER_URL}"
echo "  Tools:"
echo "    - hippocampus-remember        (remember_memory)"
echo "    - hippocampus-reflect         (reflect_consolidate)"
echo "    - hippocampus-blindspot-report (generate_blindspot_report)"
echo "    - hippocampus-export          (export_knowledge_base)"
echo "    - hippocampus-import          (import_knowledge_base)"
