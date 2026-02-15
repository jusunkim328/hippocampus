#!/usr/bin/env bash
set -euo pipefail

# Hippocampus E2E Test — Converse API
# Trust Gate 6가지 시나리오를 API 레벨에서 자동 검증 (2~5초/쿼리)
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
TOTAL=6

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
echo "[1/6] Grade A + CONFLICT — DB 커넥션 타임아웃 ..."
RESP1=$(converse "Payment 서비스에서 DB 커넥션 타임아웃이 반복 발생")
check 1 "Grade A + CONFLICT" "$RESP1" "CONFLICT|모순|contradiction|Knowledge Drift|상충"

# ── Test 2: Grade D + Blindspot ──────────────────────────────────────────────
# networking 도메인은 seed data에서 VOID (memory_count=0) → 항상 blindspot
echo "[2/6] Grade D + Blindspot — 네트워크 패킷 드롭 ..."
RESP2=$(converse "네트워크에서 간헐적 패킷 드롭이 발생하고 있습니다")
check 2 "Grade D + Blindspot" "$RESP2" "사각지대"

# ── Test 3: Remember (경험 저장) ─────────────────────────────────────────────
echo "[3/6] Remember — Redis 경험 저장 ..."
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
echo "[4/6] Reflect — 에피소드 기억 통합 ..."
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
echo "[5/6] Blindspot Report — 전체 사각지대 보고서 ..."
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
echo "[6/6] Grade 상승 — Redis 재질문 ..."
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

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL}/${TOTAL} failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
