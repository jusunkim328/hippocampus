#!/usr/bin/env bash
set -euo pipefail

# knowledge-domains-staging → knowledge-domains (lookup) 동기화
#
# lookup 모드 인덱스는 읽기 전용이므로, staging에 쌓인 데이터를
# 집계하여 lookup 인덱스를 재생성합니다.
#
# 사용법:
#   export $(cat .env | xargs)
#   bash setup/08-sync-domains.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  export $(cat "$ENV_FILE" | xargs)
fi

ES_URL="${ES_URL:?ES_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"
INDICES_DIR="${SCRIPT_DIR}/../indices"

AUTH_HEADER="Authorization: ApiKey ${ES_API_KEY}"

echo "=== Sync: knowledge-domains-staging → knowledge-domains (lookup) ==="
echo ""

# 1. staging에서 도메인별 집계 (최신 memory_count, avg_confidence 등)
echo "[1/4] Aggregating from knowledge-domains-staging ..."
AGG_RESULT=$(curl -s -X POST "${ES_URL}/knowledge-domains-staging/_search" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "size": 0,
    "aggs": {
      "by_domain": {
        "terms": { "field": "domain", "size": 100 },
        "aggs": {
          "latest": { "max": { "field": "last_updated" } },
          "avg_conf": { "avg": { "field": "avg_confidence" } },
          "max_count": { "max": { "field": "memory_count" } },
          "max_density": { "max": { "field": "density_score" } }
        }
      }
    }
  }')

BUCKET_COUNT=$(echo "$AGG_RESULT" | jq '.aggregations.by_domain.buckets | length')
echo "  Found ${BUCKET_COUNT} domains in staging"

if [ "$BUCKET_COUNT" -eq 0 ]; then
  echo "  No data in staging — skipping sync"
  exit 0
fi

# 2. lookup 인덱스 삭제
echo "[2/4] Deleting knowledge-domains (lookup index) ..."
DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "${ES_URL}/knowledge-domains" \
  -H "${AUTH_HEADER}")
echo "  HTTP ${DEL_CODE}"

# 3. lookup 모드로 재생성
echo "[3/4] Recreating knowledge-domains with index.mode: lookup ..."
CREATE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${ES_URL}/knowledge-domains" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d @"${INDICES_DIR}/knowledge-domains.json")
echo "  HTTP ${CREATE_CODE}"

# 4. 집계 결과를 bulk로 투입
echo "[4/4] Bulk indexing aggregated domains ..."
BULK_BODY=""
for row in $(echo "$AGG_RESULT" | jq -c '.aggregations.by_domain.buckets[]'); do
  DOMAIN=$(echo "$row" | jq -r '.key')
  MEM_COUNT=$(echo "$row" | jq -r '.max_count.value // 0' | awk '{printf "%d", $1}')
  AVG_CONF=$(echo "$row" | jq -r '.avg_conf.value // 0')
  LAST_UPD=$(echo "$row" | jq -r '.latest.value_as_string // empty')
  DENSITY=$(echo "$row" | jq -r '.max_density.value // 0')

  # status 계산
  STATUS="DENSE"
  if echo "$DENSITY" | awk '{exit ($1 < 1.0) ? 0 : 1}'; then
    STATUS="VOID"
  elif echo "$DENSITY" | awk '{exit ($1 < 5.0) ? 0 : 1}'; then
    STATUS="SPARSE"
  fi

  BULK_BODY="${BULK_BODY}{\"index\":{\"_index\":\"knowledge-domains\"}}
{\"domain\":\"${DOMAIN}\",\"memory_count\":${MEM_COUNT},\"avg_confidence\":${AVG_CONF},\"last_updated\":\"${LAST_UPD}\",\"density_score\":${DENSITY},\"status\":\"${STATUS}\"}
"
done

BULK_CODE=$(echo "$BULK_BODY" | curl -s -o /dev/null -w "%{http_code}" -X POST "${ES_URL}/_bulk" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/x-ndjson" \
  --data-binary @-)
echo "  HTTP ${BULK_CODE} (${BUCKET_COUNT} domains indexed)"

echo ""
echo "=== Sync complete ==="
