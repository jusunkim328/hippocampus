# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

Always communicate in Korean (한국어).

## Project Overview

Hippocampus는 Elasticsearch Agent Builder 기반의 **AI Agent Guardrails** 시스템이다. LLM이 답변 전에 조직의 경험 데이터로 자기 검증하는 "Trust Gate" 패턴을 구현한다. 핵심 차별화: Mem0/Zep은 "저장+검색", Hippocampus는 **"검증+행동 변화"**.

## Hackathon Context

[Elasticsearch Agent Builder Hackathon](https://elasticsearch.devpost.com/) 출품작.

- **마감**: 2026-02-27 1:00pm EST
- **심사**: 기술 실행력 30% / 임팩트·혁신성 30% / 데모 품질 30% / 소셜 공유 10%
- **제출 요건**: ~300단어 설명 + 3분 데모 영상 + 공개 저장소(OSI 라이선스) + 선택적 소셜 포스트(@elastic_devs)
- **데이터 규칙**: 모든 데이터는 오픈소스 또는 합성(synthetic)이어야 함 — 기밀/개인정보 금지
- **필수 기술**: Elastic Workflows, Search, ES|QL 중 하나 이상 → ES|QL 4개 도구 사용으로 충족
- **데모 스크립트**: `demo/demo-script.md` — 4막 구성
- **상세 참조**: `docs/hackathon-reference.md` — 해커톤 공식 페이지 전체 번역본

### 제출 전 체크리스트

- [ ] GitHub repo **public** 전환
- [ ] **LICENSE** 파일 추가 (MIT)
- [ ] `.env`는 `.env.example`만 포함 (실제 credential 제외)
- [ ] seed data가 **synthetic**임을 README에 명시
- [ ] ~300단어 설명 작성
- [ ] 3분 데모 영상 제작
- [ ] 소셜 미디어 포스트 (10% 가산점)

## Setup & Deployment

```bash
# Prerequisites: Elastic Cloud Hosted (ES 9.x), ELSER v2 deployed, Agent Builder enabled
# .env.example → .env 복사 후 ES_URL, ES_API_KEY, KIBANA_URL, MCP_SERVER_URL 설정

# 1. MCP 서버 배포 (Docker Compose)
docker compose up -d --build
# ngrok/cloudflared로 터널링 후 HTTPS URL을 .env의 MCP_SERVER_URL에 설정
# 스케줄러 활성화: SCHEDULER_ENABLED=true docker compose up -d

# 2. 순서대로 실행 (각 스크립트는 이전 단계에 의존)
bash setup/01-indices.sh         # 5 ES indices (ES API)
bash setup/02-ilm-policies.sh    # 2 ILM policies (ES API)
bash setup/03-tools.sh           # 4 ESQL Agent Builder tools (Kibana API)
bash setup/04-mcp-tools.sh       # MCP connector + 3 MCP tools (Kibana API)
bash setup/05-agent.sh           # 1 agent (Kibana API)
bash setup/06-seed-data.sh       # Seed data via _bulk (ES API)

# 3. Dashboard import (9.x 네이티브 포맷)
curl -X POST "${KIBANA_URL}/api/saved_objects/_import?overwrite=true" \
  -H "Authorization: ApiKey ${ES_API_KEY}" -H "kbn-xsrf: true" \
  -F file=@dashboard/hippocampus-dashboard-9x.ndjson
```

Scripts 01-02, 06 → `ES_URL`. Scripts 03-05 → `KIBANA_URL`. 모두 `ES_API_KEY` 사용. Kibana API는 `kbn-xsrf: true` + `x-elastic-internal-origin: Kibana` 헤더 필요.

### Redeployment (도구/에이전트 변경 시)

Kibana Agent Builder API는 POST로 이미 존재하는 리소스를 생성하면 400/409 반환. **삭제 후 재생성** 필요:

```bash
export $(cat .env | xargs)

# ESQL 도구 삭제 + 재등록
for tool in hippocampus-recall hippocampus-contradict hippocampus-blindspot-density hippocampus-blindspot-targeted; do
  curl -X DELETE "${KIBANA_URL}/api/agent_builder/tools/${tool}" \
    -H "Authorization: ApiKey ${ES_API_KEY}" -H "kbn-xsrf: true" -H "x-elastic-internal-origin: Kibana"
done
bash setup/03-tools.sh
bash setup/04-mcp-tools.sh  # MCP 도구 3개는 스크립트 내에서 자체 삭제+생성

# 에이전트 삭제 + 재등록
curl -X DELETE "${KIBANA_URL}/api/agent_builder/agents/hippocampus" \
  -H "Authorization: ApiKey ${ES_API_KEY}" -H "kbn-xsrf: true" -H "x-elastic-internal-origin: Kibana"
bash setup/05-agent.sh
```

## Architecture

### Trust Gate Flow (query-time)

```
Query → STEP 1: Recall + Blindspot (동시 호출)
      → STEP 2: Experience Grade 판정 (A/B/C/D)
      → STEP 3: Grade A → Contradict check
                Grade C/D → 다른 키워드로 Recall 재시도
      → Graded Response (Grade 라벨 필수 표시)
```

### Data Model (5 indices)

| Index | 용도 | 특이사항 |
|-------|------|---------|
| `episodic-memories` | Raw experience records | `semantic_text` (ELSER v2), ILM 90d delete |
| `semantic-memories` | SPO triples (entity/attribute/value) | Permanent, `semantic_text` for search |
| `knowledge-domains` | Per-domain density scores | VOID(<1) / SPARSE(<5) / DENSE(≥5) |
| `memory-associations` | Memory links (supports/contradicts/related/supersedes) | |
| `memory-access-log` | Audit trail | ILM 30d delete |

추가로 `knowledge-domains-staging` 인덱스가 MCP 서버의 reflect/blindspot에서 사용됨 (lookup index와 분리).

### Two API Surfaces

| Component | Base URL | Headers |
|-----------|----------|---------|
| Indices, ILM, Bulk data | `ES_URL` | `Authorization: ApiKey` |
| Tools, Agents, Workflows | `KIBANA_URL` | `Authorization: ApiKey` + `kbn-xsrf: true` + `x-elastic-internal-origin: Kibana` |

`KIBANA_URL`은 `ES_URL`과 **서브도메인이 다름** — ES URL에서 유도 불가.

### Agent Builder Tools (9개: 7 커스텀 + 2 플랫폼)

| 도구 | 타입 | Trust Gate 역할 |
|------|------|----------------|
| `hippocampus-recall` | esql | STEP 1 — 경험 시맨틱 검색 (상위 5건) |
| `hippocampus-blindspot-targeted` | esql | STEP 1 — 도메인 밀도 조회 |
| `hippocampus-contradict` | esql | STEP 3 — Knowledge Drift 감지 |
| `hippocampus-blindspot-density` | esql | 전체 도메인 밀도 스캔 |
| `hippocampus-remember` | mcp | 새 경험 저장 (3개 인덱스에 쓰기) |
| `hippocampus-reflect` | mcp | 에피소드 통합 (카테고리 집계 → 도메인 갱신) |
| `hippocampus-blindspot-report` | mcp | 전체 사각지대 보고서 (VOID/SPARSE/DENSE/Stale) |
| `platform.core.execute_esql` | 내장 | 메모리 인덱스 외 일반 데이터 조회용 |
| `platform.core.list_indices` | 내장 | 인덱스 목록 조회 |

`platform.core.search`는 의도적으로 **제거** — LLM이 recall 대신 범용 검색을 선택하는 문제 방지.

### Tool Types (Kibana Agent Builder API)

| 타입 | configuration 필드 | 비고 |
|------|-------------------|------|
| `esql` | `query` + `params` (object, not array; empty `{}` if no params) | |
| `mcp` | `connector_id` + `tool_name` | `.mcp` 커넥터를 통해 외부 MCP 서버 호출 |
| `index_search` | `pattern` (index pattern string) | |
| `workflow` | `workflow_id` | **사용 불가** — 실행 엔진 버그 |

### MCP Server (`mcp-server/`)

3개 MCP 도구의 백엔드. FastMCP + Streamable HTTP + Python 3.12 + httpx.

**도구:**
- `remember_memory(raw_text, entity, attribute, value, confidence, category)` — 경험 저장
- `reflect_consolidate()` — 에피소드 통합 (reflected=false → 카테고리 집계 → 도메인 갱신)
- `generate_blindspot_report()` — 사각지대 보고서 (VOID/SPARSE/DENSE/Stale)

**환경변수:**
| 변수 | 기본값 | 설명 |
|------|--------|------|
| `ES_URL` | (필수) | Elasticsearch URL |
| `ES_API_KEY` | (필수) | API Key |
| `PORT` | `8080` | 서버 포트 |
| `SCHEDULER_ENABLED` | `false` | 백그라운드 스케줄러 활성화 |
| `REFLECT_INTERVAL_SECONDS` | `21600` (6h) | reflect 주기 |
| `BLINDSPOT_INTERVAL_SECONDS` | `86400` (24h) | blindspot 주기 |

**배포:** `docker compose up -d --build` → ngrok/cloudflared로 HTTPS 터널링. `.mcp` Kibana 커넥터가 `MCP_SERVER_URL`로 연결.

**스케줄러:** 각 도구별 독립 daemon thread + 독립 asyncio event loop. `SCHEDULER_ENABLED=true`로 활성화.

## Known Issues & Pitfalls

### Elastic Workflow 실행 엔진 버그

ES 9.3.0 Technical Preview에서 등록은 성공하지만 실행이 즉시 실패. 3개 워크플로우 모두 MCP로 전환 완료. YAML은 `workflows/`에 참조용 보존.

```
[Before] Agent → workflow tool → Elastic Workflow engine → ES  (❌ 실행 실패)
[After]  Agent → mcp tool → .mcp connector → MCP server → ES  (✅ 정상)
```

### ES 데이터 타입 주의

- `importance` 필드가 ES에서 string으로 반환될 수 있음 → 반드시 `float()` 변환 필요
- `semantic_text` 필드가 `_cat/indices` doc count를 2배로 표시 (ELSER inference chunks) → `_count` API로 실제 수 확인

### macOS 셸 호환성

- `head -n -1`은 macOS에서 동작하지 않음 → `sed '$d'` 사용
- 쉘 스크립트에서 `python3 -c` 안에 중첩된 `$()` 사용 시 구문 에러 발생 → `os.environ` + temp file 패턴 사용

### Kibana Agent Builder UI 버그: 에이전트 선택 미적용

새 대화에서 에이전트가 시각적으로 선택되어 있어도 실제로는 기본 "Elastic AI Agent"가 사용됨. 반드시 **다른 에이전트로 전환 후 다시 돌아와야** 상태 변경 이벤트가 트리거됨:

```
1. /app/agent_builder/conversations/new로 네비게이션
2. 에이전트 선택 → "Elastic AI Agent" 클릭 (기본으로 전환)
3. 다시 에이전트 선택 → "Hippocampus Trust Gate" 클릭
```

### 9.x Dashboard NDJSON 포맷

코드 생성한 NDJSON import 시 "Visualization type not found" 실패 빈번. **안전한 방법: Kibana UI에서 직접 생성 후 export.**

필수 규칙:
- `panelIndex`: UUID 형식 (`panel-1` 금지)
- `embeddableConfig`: `{}` (`{"enhancements":{}}` 금지)
- Panel에 `version`/`panelRefName` 필드 없음
- Lens state: `isBucketed`, `emptyAsNull`, `colorMapping`, `sampling`, `ignoreGlobalFilters` 필수
- Lens datasourceStates: `formBased`, `indexpattern`, `textBased` 3개 모두 필요

## E2E Testing

### API 테스트 (권장 — 2~5초)

```bash
export $(cat .env | xargs)
bash test/e2e-test.sh     # 4 시나리오: Grade A+CONFLICT, Grade D+Blindspot, Remember, Grade 상승
bash setup/07-verify.sh   # A2A 메타데이터 + Converse API + 에이전트 등록 확인
```

### MCP 서버 직접 테스트

```bash
# reflect
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"reflect_consolidate","arguments":{}}}'

# blindspot report
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"generate_blindspot_report","arguments":{}}}'
```

### UI 테스트 (Playwright MCP)

Agent Builder UI 테스트는 **Playwright MCP** 사용 (Chrome DevTools는 브라우저 이중 실행 방지를 위해 금지). 응답 25~45초 소요 → `browser_wait_for(text="Experience Grade", time=45)`.

## Project Structure

```
hippocampus/
├── agent/hippocampus-agent.json   # 에이전트 정의 (instructions + tool_ids)
├── tools/*.json                   # 4 ESQL 도구 정의 (recall, contradict, blindspot-density, blindspot-targeted)
├── workflows/*.yaml               # 3 워크플로우 (참조용, 미사용)
├── mcp-server/
│   ├── server.py                  # FastMCP 서버 (3 tools + scheduler)
│   ├── Dockerfile                 # Python 3.12-slim
│   └── requirements.txt           # fastmcp, httpx, uvicorn
├── setup/
│   ├── 01-indices.sh              # ES indices 생성
│   ├── 02-ilm-policies.sh         # ILM policies
│   ├── 03-tools.sh                # ESQL 도구 4개 등록
│   ├── 04-mcp-tools.sh            # MCP 커넥터 + 도구 3개 등록
│   ├── 04-workflows.sh            # Workflow 등록 (미사용)
│   ├── 05-agent.sh                # 에이전트 등록
│   ├── 06-seed-data.sh            # Seed data
│   ├── 07-verify.sh               # 검증 스크립트
│   └── 08-sync-domains.sh         # 도메인 동기화
├── test/e2e-test.sh               # E2E 4개 시나리오
├── dashboard/*.ndjson             # Kibana 대시보드
├── seed/*.ndjson                  # Seed data (synthetic)
├── demo/demo-script.md            # 데모 스크립트
├── docker-compose.yml             # MCP 서버 Docker Compose
├── .env.example                   # 환경변수 템플릿
└── .env                           # 실제 환경변수 (gitignored)
```

## Agent Instructions 설계 원칙

- **MUST/NEVER 강제어** — 서술형 대신 규칙 기반
- **STEP 넘버링** — 도구 호출 순서 명시적 강제
- **도구 description에 프로토콜 연결 정보** — "Trust Gate STEP 1 필수 도구" 등
- **범용 검색 도구 제거** — `platform.core.search`가 있으면 LLM이 recall 대신 선택
- **recall KEEP 필드에 entity/attribute/value** — contradict 호출 시 추가 API 호출 방지 (8→3~4 calls)
- **고정 출력 템플릿** — Grade 라벨을 "모든 답변의 첫 부분에 반드시 표시"로 강제

## Working Preferences

- 무언가의 작업을 대기할 때는 Exponential Backoff 방식으로 해
- 개발 작업할 때는 Agent Teams 사용을 항상 검토해
