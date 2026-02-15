#!/usr/bin/env bash
set -euo pipefail

# Hippocampus E2E Test — Converse API + MCP Direct
# Automated Trust Gate 10-scenario verification at API level (2~5s/query)
#
# Usage:
#   export $(cat .env | xargs)
#   bash test/e2e-test.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  export $(cat "$ENV_FILE" | xargs)
fi

KIBANA_URL="${KIBANA_URL:?KIBANA_URL is required. Set it in .env}"
ES_URL="${ES_URL:?ES_URL is required. Set it in .env}"
ES_API_KEY="${ES_API_KEY:?ES_API_KEY is required. Set it in .env}"

AGENT_ID="hippocampus"
PASS=0
FAIL=0
TOTAL=10
MCP_URL="${MCP_URL:-https://hippocampus-mcp-1096006807994.asia-northeast3.run.app}"
MCP_AUTH_TOKEN="${MCP_AUTH_TOKEN:-}"

# ── helpers ──────────────────────────────────────────────────────────────────

# Direct MCP server call (Bearer token auto-included)
mcp_call() {
  local args=(-s -X POST "${MCP_URL}/mcp" -H "Content-Type: application/json" -H "Accept: application/json")
  if [ -n "$MCP_AUTH_TOKEN" ]; then
    args+=(-H "Authorization: Bearer ${MCP_AUTH_TOKEN}")
  fi
  curl "${args[@]}" "$@"
}

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
    echo "        -> .content field missing. Response:"
    echo "$response" | head -5
    FAIL=$((FAIL + 1))
    return
  fi

  # Check Experience Grade or Trust Card label presence
  if ! echo "$content" | grep -qE "Experience Grade|Trust Card"; then
    echo "  FAIL  #${test_num} ${label}"
    echo "        -> 'Experience Grade / Trust Card' label missing"
    echo "        -> First 200 chars: ${content:0:200}"
    FAIL=$((FAIL + 1))
    return
  fi

  # Check scenario-specific keywords
  if ! echo "$content" | grep -qiE "$keyword"; then
    echo "  FAIL  #${test_num} ${label}"
    echo "        -> '${keyword}' keyword missing"
    echo "        -> First 200 chars: ${content:0:200}"
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

# ── Test 1: Grade A — DB connection timeout (experience-rich domain) ────────────────
echo "[1/10] Grade A — DB connection timeout ..."
RESP1=$(converse "DB connection timeouts keep recurring in Payment service")
check 1 "Grade A" "$RESP1" "Grade: A|timeout|connection|pool|HikariCP"

# ── Test 2: Grade D + Blindspot ──────────────────────────────────────────────
# networking domain is VOID in seed data (memory_count=0) -> always blindspot
echo "[2/10] Grade D + Blindspot — network packet drops ..."
RESP2=$(converse "Intermittent packet drops occurring in the network")
check 2 "Grade D + Blindspot" "$RESP2" "blindspot|Blindspot|VOID|Grade: D"

# ── Test 3: Remember (experience storage) ─────────────────────────────────────────────
echo "[3/10] Remember — Redis experience storage ..."
RESP3=$(converse "Just resolved Redis latency by increasing maxmemory to 4GB. Please save this experience.")
CONTENT3=$(echo "$RESP3" | jq -r '.response.message // .content // empty' 2>/dev/null)

# Check remember tool invocation: success if response contains save-related keywords
if echo "$CONTENT3" | grep -qiE "saved|stored|remember|recorded|Saved"; then
  echo "  PASS  #3 Remember (experience stored)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #3 Remember (experience stored)"
  echo "        -> 'saved/stored/remember/recorded' keyword missing"
  echo "        -> First 200 chars: ${CONTENT3:0:200}"
  FAIL=$((FAIL + 1))
fi

# ── Test 4: Reflect (episode consolidation) ────────────────────────────────────────
echo "[4/10] Reflect — episode memory consolidation ..."
RESP4=$(converse "Please consolidate episodic memories")
CONTENT4=$(echo "$RESP4" | jq -r '.response.message // .content // empty' 2>/dev/null)

if [ -z "$CONTENT4" ]; then
  echo "  FAIL  #4 Reflect (episode consolidation)"
  echo "        -> .content field missing"
  FAIL=$((FAIL + 1))
elif echo "$CONTENT4" | grep -qiE "consolidat|reflect|episode|domain|SPARSE|DENSE"; then
  echo "  PASS  #4 Reflect (episode consolidation)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #4 Reflect (episode consolidation)"
  echo "        -> consolidate/reflect/episode/domain keyword missing"
  echo "        -> First 200 chars: ${CONTENT4:0:200}"
  FAIL=$((FAIL + 1))
fi

# ── Test 5: Blindspot Report ────────────────────────────────────
echo "[5/10] Blindspot Report — full blindspot report ..."
RESP5=$(converse "Generate a knowledge blindspot report")
CONTENT5=$(echo "$RESP5" | jq -r '.response.message // .content // empty' 2>/dev/null)

if [ -z "$CONTENT5" ]; then
  echo "  FAIL  #5 Blindspot Report"
  echo "        -> .content field missing"
  FAIL=$((FAIL + 1))
elif echo "$CONTENT5" | grep -qiE "VOID|SPARSE|DENSE|Stale|blindspot|Blindspot"; then
  echo "  PASS  #5 Blindspot Report"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #5 Blindspot Report"
  echo "        -> VOID/SPARSE/DENSE/Stale/blindspot keyword missing"
  echo "        -> First 200 chars: ${CONTENT5:0:200}"
  FAIL=$((FAIL + 1))
fi

# ── Test 6: Grade upgrade (re-query after save) ─────────────────────────────────────
echo "[6/10] Grade upgrade — Redis re-query ..."
# Wait for indexing after save (includes semantic_text inference)
sleep 3
RESP6=$(converse "How to resolve Redis cache latency?")
CONTENT6=$(echo "$RESP6" | jq -r '.response.message // .content // empty' 2>/dev/null)

# Success if not Grade D (A, B, C all count as upgrade)
if echo "$CONTENT6" | grep -qE "Experience Grade|Trust Card"; then
  if echo "$CONTENT6" | grep -q "Grade: D"; then
    echo "  FAIL  #6 Grade upgrade (expected D->A/B)"
    echo "        -> still Grade D"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS  #6 Grade upgrade (D->A/B)"
    PASS=$((PASS + 1))
  fi
else
  echo "  FAIL  #6 Grade upgrade"
  echo "        -> 'Experience Grade / Trust Card' label missing"
  echo "        -> First 200 chars: ${CONTENT6:0:200}"
  FAIL=$((FAIL + 1))
fi

# ── Test 7: Export/Import Roundtrip (direct MCP call) ────────────────────────────
echo "[7/10] Export/Import Roundtrip — direct MCP test ..."

# File-based processing (prevents large NDJSON shell pipe breakage)
mcp_call \
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
# Extract 3-line sample (1 per _type) + generate import payload
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
  # 7b. Import (3-line sample roundtrip)
  IMPORT_RESP=$(mcp_call -d @/tmp/e2e_import_payload.json)

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
    echo "  PASS  #7 Export/Import Roundtrip (exported ${EXPORT_TOTAL}, imported ${IMPORT_OK})"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  #7 Export/Import Roundtrip (import failed)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  #7 Export/Import Roundtrip (export 0 documents)"
  FAIL=$((FAIL + 1))
fi

# ── Test 8: MCP Health — tools/list verification ───────────────────────────
echo "[8/10] MCP Health — tools/list verification ..."

TOOLS_RESP=$(mcp_call -d '{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{}}')

TOOLS_OK=$(echo "$TOOLS_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    tools = data.get('result',{}).get('tools',[])
    names = sorted([t['name'] for t in tools])
    expected = ['export_knowledge_base','generate_blindspot_report','import_knowledge_base','reflect_consolidate','remember_memory','sync_knowledge_domains']
    if names == expected:
        print('PASS')
    else:
        print(f'MISMATCH: got {names}')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)

if [ "$TOOLS_OK" = "PASS" ]; then
  echo "  PASS  #8 MCP Health (6 tools verified)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  #8 MCP Health"
  echo "        -> ${TOOLS_OK}"
  FAIL=$((FAIL + 1))
fi

# ── Test 9: External Refs — remember with refs + recall verification ────────────────
echo "[9/10] External Refs — remember with refs + recall verification ..."

# 9a. remember_memory with external_refs (direct MCP call)
REMEMBER_REF_RESP=$(mcp_call -d '{
    "jsonrpc":"2.0","id":9,"method":"tools/call",
    "params":{"name":"remember_memory","arguments":{
      "raw_text":"e2e-test: Kafka consumer lag persisting over 30min requires partition rebalancing",
      "entity":"kafka-cluster","attribute":"consumer-lag-threshold","value":"30min",
      "confidence":"high","category":"messaging",
      "external_refs":"KAFKA-789, https://wiki.internal/kafka-ops"
    }}
  }')

REMEMBER_REF_OK=$(echo "$REMEMBER_REF_RESP" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    text = data.get('result',{}).get('content',[{}])[0].get('text','')
    if 'episodic' in text.lower() or 'saved' in text.lower() or 'Saved' in text:
        print('PASS')
    else:
        print(f'UNEXPECTED: {text[:200]}')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)

if [ "$REMEMBER_REF_OK" = "PASS" ]; then
  # 9b. Verify external_refs in ES (wait for indexing)
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
    echo "  PASS  #9 External Refs (saved + ES verified)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  #9 External Refs (ES verification failed)"
    echo "        -> ${REFS_CHECK}"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL  #9 External Refs (remember failed)"
  echo "        -> ${REMEMBER_REF_OK}"
  FAIL=$((FAIL + 1))
fi

# ── Test 10: Import CONFLICT — detect conflict with existing semantic ────────────────────
echo "[10/10] Import CONFLICT — detect conflict with existing semantic ..."

# kafka-cluster / consumer-lag-threshold = "30min" was just saved in seed data
# Import with different value -> expect CONFLICT
CONFLICT_PAYLOAD=$(python3 -c "
import json
ndjson_line = json.dumps({
    'entity': 'kafka-cluster',
    'attribute': 'consumer-lag-threshold',
    'value': 'changed to 10min',
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

CONFLICT_RESP=$(echo "$CONFLICT_PAYLOAD" | mcp_call -d @-)

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
  echo "  PASS  #10 Import CONFLICT (${CONFLICT_COUNT} conflict(s) detected)"
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
