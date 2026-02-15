#!/usr/bin/env bash
set -euo pipefail

# Hippocampus E2E Test — Converse API + MCP Direct
# Trust Gate 10가지 시나리오를 API 레벨에서 자동 검증 (2~5초/쿼리)
#
# 사용법:
#   export $(cat .env | xargs)
#   bash test/e2e-test.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  export $(cat "$ENV_FILE" | xargs)
fi

KIBANA_URL="${KIBANA_URL:?KIBANA_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"

AGENT_ID="hippocampus"
PASS=0
FAIL=0
TOTAL=10
MCP_URL="${MCP_URL:-http://localhost:8080}"

# ── helpers ──────────────────────────────────────────────────────────────────

converse() {
  local query="$1"
  curl -s -X POST "${KIBANA_URL}/api/agent_builder/converse" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -d "{\"agent_id\": \"${AGENT_ID}\", \"input\": \"${query}\"}"
}

check() {
  local test_num="$1"
  local label="$2"
  local response="$3"
  local keyword="$4"

  local content
  content=$(echo "$response" | jq -r '.response.message // .content // empty' 2>/dev/null)

  if [ -z "$content" ]; then
    echo "  FAIL  #${test_num} ${label}"
    echo "        -> .content 필드 없음. 응답:"
    echo "$response" | head -5
    FAIL=$((FAIL + 1))
    return
  fi

  # Experience Grade 라벨 존재 확인
  if ! echo "$content" | grep -q "Experience Grade"; then
    echo "  FAIL  #${test_num} ${label}"
    echo "        -> 'Experience Grade' 라벨 없음"
    echo "        -> 응답 첫 200자: ${content:0:200}"
    FAIL=$((FAIL + 1))
    return
  fi

  # 시나리오별 키워드 확인
  if ! echo "$content" | grep -qiE "$keyword"; then
    echo "  FAIL  #${test_num} ${label}"
    echo "        -> '${keyword}' 키워드 없음"
    echo "        -> 응답 첫 200자: ${content:0:200}"
    FAIL=$((FAIL + 1))
    return
  fi

  echo "  PASS  #${test_num} ${label}"
  PASS=$((PASS + 1))
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "=== Hippocampus E2E Test (Converse API) ==="
echo "KIBANA_URL: ${KIBANA_URL}"
echo "AGENT_ID:   ${AGENT_ID}"
echo ""

# ── Test 1: Grade A + CONFLICT ──────────────────────────────────────────────
echo "[1/10] Grade A + CONFLICT — DB 커넥션 타임아웃 ..."
RESP1=$(converse "Payment 서비스에서 DB 커넥션 타임아웃이 반복 발생")
check 1 "Grade A + CONFLICT" "$RESP1" "CONFLICT|모순|contradiction|Knowledge Drift|상충"

# ── Test 2: Grade D + Blindspot ──────────────────────────────────────────────
# networking 도메인은 seed data에서 VOID (memory_count=0) → 항상 blindspot
echo "[2/10] Grade D + Blindspot — 네트워크 패킷 드롭 ..."
RESP2=$(converse "네트워크에서 간헐적 패킷 드롭이 발생하고 있습니다")
check 2 "Grade D + Blindspot" "$RESP2" "사각지대"

# ── Test 3: Remember (경험 저장) ─────────────────────────────────────────────
echo "[3/10] Remember — Redis 경험 저장 ..."
RESP3=$(converse "방금 Redis maxmemory를 4GB로 증설해서 해결했습니다. 저장해주세요")
CONTENT3=$(echo "$RESP3" | jq -r '.response.message // .content // empty' 2>/dev/null)

# remember 도구 호출 확인: 응답에 "저장" 관련 키워드가 있으면 성공
if echo "$CONTENT3" | grep -qiE "저장|remember|기록|학습"; then
  echo "  PASS  #3 Remember (경험 저장)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #3 Remember (경험 저장)"
  echo "        -> '저장/remember/기록/학습' 키워드 없음"
  echo "        -> 응답 첫 200자: ${CONTENT3:0:200}"
  FAIL=$((FAIL + 1))
fi

# ── Test 4: Reflect (에피소드 통합) ────────────────────────────────────────
echo "[4/10] Reflect — 에피소드 기억 통합 ..."
RESP4=$(converse "에피소드 기억을 통합 분석해주세요")
CONTENT4=$(echo "$RESP4" | jq -r '.response.message // .content // empty' 2>/dev/null)

if [ -z "$CONTENT4" ]; then
  echo "  FAIL  #4 Reflect (에피소드 통합)"
  echo "        -> .content 필드 없음"
  FAIL=$((FAIL + 1))
elif echo "$CONTENT4" | grep -qiE "통합|consolidat|에피소드|reflect|도메인|SPARSE|DENSE"; then
  echo "  PASS  #4 Reflect (에피소드 통합)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #4 Reflect (에피소드 통합)"
  echo "        -> 통합/consolidate/에피소드/도메인 키워드 없음"
  echo "        -> 응답 첫 200자: ${CONTENT4:0:200}"
  FAIL=$((FAIL + 1))
fi

# ── Test 5: Blindspot Report (사각지대 보고서) ────────────────────────────────
echo "[5/10] Blindspot Report — 전체 사각지대 보고서 ..."
RESP5=$(converse "지식 사각지대 보고서를 생성해주세요")
CONTENT5=$(echo "$RESP5" | jq -r '.response.message // .content // empty' 2>/dev/null)

if [ -z "$CONTENT5" ]; then
  echo "  FAIL  #5 Blindspot Report"
  echo "        -> .content 필드 없음"
  FAIL=$((FAIL + 1))
elif echo "$CONTENT5" | grep -qiE "VOID|SPARSE|DENSE|Stale|사각지대|blindspot"; then
  echo "  PASS  #5 Blindspot Report (사각지대 보고서)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #5 Blindspot Report"
  echo "        -> VOID/SPARSE/DENSE/Stale/사각지대 키워드 없음"
  echo "        -> 응답 첫 200자: ${CONTENT5:0:200}"
  FAIL=$((FAIL + 1))
fi

# ── Test 6: Grade 상승 (저장 후 재질문) ─────────────────────────────────────
echo "[6/10] Grade 상승 — Redis 재질문 ..."
# 저장 후 인덱싱 대기 (semantic_text 추론 포함)
sleep 3
RESP6=$(converse "Redis 캐시 지연 해결 방법을 알려주세요")
CONTENT6=$(echo "$RESP6" | jq -r '.response.message // .content // empty' 2>/dev/null)

# Grade D가 아니면 성공 (A, B, C 모두 상승으로 간주)
if echo "$CONTENT6" | grep -q "Experience Grade"; then
  if echo "$CONTENT6" | grep -q "Grade: D"; then
    echo "  FAIL  #6 Grade 상승 (D→A/B 기대)"
    echo "        -> 여전히 Grade D"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  #6 Grade 상승 (D→A/B)"
    PASS=$((PASS + 1))
  fi
else
  echo "  FAIL  #6 Grade 상승"
  echo "        -> 'Experience Grade' 라벨 없음"
  echo "        -> 응답 첫 200자: ${CONTENT6:0:200}"
  FAIL=$((FAIL + 1))
fi

# ── Test 7: Export/Import Roundtrip (MCP 직접 호출) ────────────────────────────
echo "[7/10] Export/Import Roundtrip — MCP 서버 직접 테스트 ..."

# 파일 기반으로 처리 (대용량 NDJSON 셸 파이프 깨짐 방지)
curl -s -X POST "${MCP_URL}/mcp" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"export_knowledge_base","arguments":{}}}' \
  -o /tmp/e2e_export_resp.json

EXPORT_TOTAL=$(python3 -c "
import json
with open('/tmp/e2e_export_resp.json') as f:
    data = json.load(f)
text = data.get('result',{}).get('content',[{}])[0].get('text','')
parsed = json.loads(text)
counts = parsed.get('counts',{})
total = sum(counts.values())
ndjson = parsed.get('ndjson','')
# 3줄 샘플 추출 (각 _type 1건씩) + import payload 생성
lines = [l for l in ndjson.split('\n') if l.strip()]
sample, seen = [], set()
for l in lines:
    t = json.loads(l).get('_type','')
    if t not in seen and len(sample) < 3:
        sample.append(l)
        seen.add(t)
sample_ndjson = '\n'.join(sample)
payload = json.dumps({
    'jsonrpc': '2.0', 'id': 8, 'method': 'tools/call',
    'params': {'name': 'import_knowledge_base', 'arguments': {'ndjson': sample_ndjson}}
}, ensure_ascii=False)
with open('/tmp/e2e_import_payload.json', 'w') as fw:
    fw.write(payload)
print(total)
" 2>/dev/null)

if [ "$EXPORT_TOTAL" -gt 0 ] 2>/dev/null; then
  # 7b. Import (샘플 3줄 라운드트립)
  IMPORT_RESP=$(curl -s -X POST "${MCP_URL}/mcp" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -d @/tmp/e2e_import_payload.json)

  IMPORT_OK=$(echo "$IMPORT_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    text = data.get('result',{}).get('content',[{}])[0].get('text','')
    parsed = json.loads(text)
    total = sum(parsed.get('imported',{}).values())
    print(total)
except: print(0)
" 2>/dev/null)

  if [ "$IMPORT_OK" -gt 0 ] 2>/dev/null; then
    echo "  PASS  #7 Export/Import Roundtrip (export ${EXPORT_TOTAL}건, import ${IMPORT_OK}건)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  #7 Export/Import Roundtrip (import 실패)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  #7 Export/Import Roundtrip (export 0건)"
  FAIL=$((FAIL + 1))
fi

# ── Test 8: MCP Health — tools/list 도구 목록 검증 ───────────────────────────
echo "[8/10] MCP Health — tools/list 도구 목록 검증 ..."

TOOLS_RESP=$(curl -s -X POST "${MCP_URL}/mcp" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{}}')

TOOLS_OK=$(echo "$TOOLS_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    tools = data.get('result',{}).get('tools',[])
    names = sorted([t['name'] for t in tools])
    expected = ['export_knowledge_base','generate_blindspot_report','import_knowledge_base','reflect_consolidate','remember_memory']
    if names == expected:
        print('PASS')
    else:
        print(f'MISMATCH: got {names}')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)

if [ "$TOOLS_OK" = "PASS" ]; then
  echo "  PASS  #8 MCP Health (5개 도구 확인)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #8 MCP Health"
  echo "        -> ${TOOLS_OK}"
  FAIL=$((FAIL + 1))
fi

# ── Test 9: External Refs — remember with refs + recall 확인 ────────────────
echo "[9/10] External Refs — remember with refs + recall 확인 ..."

# 9a. remember_memory with external_refs (MCP 직접 호출)
REMEMBER_REF_RESP=$(curl -s -X POST "${MCP_URL}/mcp" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{
    "jsonrpc":"2.0","id":9,"method":"tools/call",
    "params":{"name":"remember_memory","arguments":{
      "raw_text":"e2e-test: Kafka consumer lag이 30분 이상 지속되면 파티션 리밸런싱 필요",
      "entity":"kafka-cluster","attribute":"consumer-lag-threshold","value":"30분",
      "confidence":"high","category":"messaging",
      "external_refs":"KAFKA-789, https://wiki.internal/kafka-ops"
    }}
  }')

REMEMBER_REF_OK=$(echo "$REMEMBER_REF_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    text = data.get('result',{}).get('content',[{}])[0].get('text','')
    if 'episodic' in text.lower() or '저장' in text:
        print('PASS')
    else:
        print(f'UNEXPECTED: {text[:200]}')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)

if [ "$REMEMBER_REF_OK" = "PASS" ]; then
  # 9b. ES에서 external_refs 확인 (인덱싱 대기)
  sleep 2
  REFS_CHECK=$(curl -s -X POST "${ES_URL}/episodic-memories/_search" \
    -H "Authorization: ApiKey ${ES_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"query":{"match":{"raw_text":"e2e-test: Kafka consumer lag"}},"size":1,"_source":["external_refs"]}' \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    hits = data.get('hits',{}).get('hits',[])
    if hits:
        refs = hits[0].get('_source',{}).get('external_refs',[])
        if 'KAFKA-789' in refs and 'https://wiki.internal/kafka-ops' in refs:
            print('PASS')
        else:
            print(f'REFS_MISSING: {refs}')
    else:
        print('NO_HIT')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)

  if [ "$REFS_CHECK" = "PASS" ]; then
    echo "  PASS  #9 External Refs (저장 + ES 검증)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  #9 External Refs (ES 검증 실패)"
    echo "        -> ${REFS_CHECK}"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  #9 External Refs (remember 실패)"
  echo "        -> ${REMEMBER_REF_OK}"
  FAIL=$((FAIL + 1))
fi

# ── Test 10: Import CONFLICT — 기존 semantic과 충돌 감지 ────────────────────
echo "[10/10] Import CONFLICT — 기존 semantic과 충돌 감지 ..."

# seed data에 kafka-cluster / consumer-lag-threshold = "30분" 이 방금 저장됨
# 다른 value로 import → CONFLICT 발생 기대
CONFLICT_PAYLOAD=$(python3 -c "
import json
ndjson_line = json.dumps({
    'entity': 'kafka-cluster',
    'attribute': 'consumer-lag-threshold',
    'value': '10분으로 변경',
    'confidence': 0.8,
    'category': 'messaging',
    'first_observed': '2026-02-15T00:00:00Z',
    'last_updated': '2026-02-15T00:00:00Z',
    'update_count': 1,
    '_type': 'semantic'
}, ensure_ascii=False)
payload = json.dumps({
    'jsonrpc': '2.0', 'id': 10, 'method': 'tools/call',
    'params': {'name': 'import_knowledge_base', 'arguments': {'ndjson': ndjson_line}}
}, ensure_ascii=False)
print(payload)
")

CONFLICT_RESP=$(echo "$CONFLICT_PAYLOAD" | curl -s -X POST "${MCP_URL}/mcp" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d @-)

CONFLICT_OK=$(echo "$CONFLICT_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    text = data.get('result',{}).get('content',[{}])[0].get('text','')
    parsed = json.loads(text)
    conflicts = parsed.get('conflicts', [])
    if len(conflicts) > 0 and any(c.get('entity') == 'kafka-cluster' for c in conflicts):
        print(f'PASS:{len(conflicts)}')
    else:
        print(f'NO_CONFLICT: {text[:200]}')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)

if echo "$CONFLICT_OK" | grep -q "^PASS"; then
  CONFLICT_COUNT=$(echo "$CONFLICT_OK" | cut -d: -f2)
  echo "  PASS  #10 Import CONFLICT (${CONFLICT_COUNT}건 충돌 감지)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #10 Import CONFLICT"
  echo "        -> ${CONFLICT_OK}"
  FAIL=$((FAIL + 1))
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL}/${TOTAL} failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
