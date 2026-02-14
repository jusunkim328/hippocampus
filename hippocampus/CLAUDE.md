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
- **필수 기술**: Elastic Workflows, Search, ES|QL 중 하나 이상 → 우리는 ES|QL 4개 도구 사용으로 충족
- **데모 스크립트**: `demo/demo-script.md` — 4막 구성 (Trust Gate OFF → CONFLICT 감지 → Blindspot 감지 → Growth + Dashboard)
- **상세 참조**: `docs/hackathon-reference.md` — 해커톤 공식 페이지 전체 번역본

### 제출 전 체크리스트

- [ ] GitHub repo **public** 전환
- [ ] **LICENSE** 파일 추가 (MIT — README에 MIT 명시되어 있으나 파일 미존재)
- [ ] `.env`는 `.env.example`만 포함 (실제 credential 제외 — `.gitignore`에 `.env` 있음)
- [ ] seed data가 **synthetic**임을 README에 명시
- [ ] ~300단어 설명 작성
- [ ] 3분 데모 영상 제작
- [ ] 소셜 미디어 포스트 (10% 가산점)

## Setup & Deployment

```bash
# Prerequisites: Elastic Cloud Hosted (ES 9.x), ELSER v2 deployed, Agent Builder enabled
# Copy .env.example to .env and fill in ES_URL, ES_API_KEY, KIBANA_URL, MCP_SERVER_URL

# 1. MCP 서버 배포 (Docker) — remember 도구의 백엔드
docker build -t hippocampus-mcp mcp-server/
# 배포 후 HTTPS URL을 .env의 MCP_SERVER_URL에 설정

# 2. Deploy in order (each script depends on the previous)
bash setup/01-indices.sh         # 5 ES indices (ES API)
bash setup/02-ilm-policies.sh    # 2 ILM policies (ES API)
bash setup/03-tools.sh           # 4 ESQL Agent Builder tools (Kibana API)
bash setup/04-mcp-remember.sh    # MCP connector + remember tool (Kibana API)
bash setup/05-agent.sh           # 1 agent (Kibana API)
bash setup/06-seed-data.sh       # Seed data via _bulk (ES API)

# 3. Dashboard import (9.x 네이티브 포맷)
curl -X POST "${KIBANA_URL}/api/saved_objects/_import?overwrite=true" \
  -H "Authorization: ApiKey ${ES_API_KEY}" -H "kbn-xsrf: true" \
  -F file=@dashboard/hippocampus-dashboard-9x.ndjson

# Optional: Elastic Workflows (동작하지 않음 — 아래 "Workflow 실행 엔진 문제" 참조)
bash setup/04-workflows.sh       # 3 scheduled Elastic Workflows (Kibana API)
```

Scripts 01-02, 06 target `ES_URL`. Scripts 03-05 target `KIBANA_URL`. Both use `ES_API_KEY` for auth. Kibana API requires `kbn-xsrf: true` header.

### Redeployment (도구/에이전트 변경 시)

Kibana Agent Builder API는 POST로 이미 존재하는 리소스를 생성하면 400/409 반환. **삭제 후 재생성** 필요:

```bash
export $(cat .env | xargs)

# 도구 삭제 + 재등록
for tool in hippocampus-recall hippocampus-contradict hippocampus-blindspot-density hippocampus-blindspot-targeted; do
  curl -X DELETE "${KIBANA_URL}/api/agent_builder/tools/${tool}" \
    -H "Authorization: ApiKey ${ES_API_KEY}" -H "kbn-xsrf: true" -H "x-elastic-internal-origin: Kibana"
done
bash setup/03-tools.sh
bash setup/04-mcp-remember.sh  # remember 도구는 자체적으로 삭제+생성

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

### Data Model

- **episodic-memories**: Raw experience records, `semantic_text` (ELSER `.elser-2-elastic`), ILM 90d delete
- **semantic-memories**: SPO triples (entity/attribute/value), permanent, `semantic_text` for search
- **knowledge-domains**: Per-domain density scores. `density = memory_count × avg_confidence`. VOID(<1) / SPARSE(<5) / DENSE(≥5)
- **memory-associations**: Links between memories (supports/contradicts/related/supersedes)
- **memory-access-log**: Audit trail, ILM 30d delete

### Two API Surfaces

| Component | API | Base URL | Headers |
|-----------|-----|----------|---------|
| Indices, ILM, Bulk data | Elasticsearch REST API | `ES_URL` | `Authorization: ApiKey` |
| Tools, Agents, Workflows | Kibana API | `KIBANA_URL` | `Authorization: ApiKey` + `kbn-xsrf: true` + `x-elastic-internal-origin: Kibana` |

Kibana URL has a **different subdomain** from ES URL (found via SAML config in cluster settings, not derivable from ES URL).

### Agent Builder 도구 (5개 커스텀 + 2개 플랫폼)

| 도구 | 타입 | Trust Gate 역할 |
|------|------|----------------|
| `hippocampus-recall` | esql | STEP 1 — 경험 시맨틱 검색 (episodic + semantic, 상위 5건) |
| `hippocampus-blindspot-targeted` | esql | STEP 1 — 도메인 밀도 조회 (VOID/SPARSE/DENSE) |
| `hippocampus-contradict` | esql | STEP 3 — Knowledge Drift 감지 (Grade A일 때) |
| `hippocampus-blindspot-density` | esql | 전체 도메인 밀도 스캔 |
| `hippocampus-remember` | mcp | 새 경험 저장 (3개 인덱스에 쓰기) |
| `platform.core.execute_esql` | 내장 | 메모리 인덱스 외 일반 ES 데이터 조회용. **메모리 검색에 사용 금지** (Instructions RULE 1) |
| `platform.core.list_indices` | 내장 | 인덱스 목록 조회 |

`platform.core.search`는 의도적으로 **제거**됨 — LLM이 `hippocampus-recall` 대신 범용 검색 도구를 우선 선택하는 문제 방지.

### Tool Types (Kibana Agent Builder API)

- `esql`: `configuration.query` + `configuration.params` (object, not array; empty `{}` if no params)
- `mcp`: `configuration.connector_id` + `configuration.tool_name` — `.mcp` 커넥터를 통해 외부 MCP 서버 호출
- `index_search`: `configuration.pattern` (index pattern string)
- `workflow`: `configuration.workflow_id` — **사용 불가, 아래 참조**

### MCP 서버 (`mcp-server/`)

`hippocampus-remember` 도구의 백엔드. Elastic Workflows 실행 엔진 버그로 인해 MCP로 전환.

- **스택**: FastMCP, Streamable HTTP transport, Python 3.12, httpx
- **도구**: `remember_memory(raw_text, entity, attribute, value, confidence, category)` 1개
- **동작**: ES REST API로 3개 인덱스(episodic-memories, semantic-memories, knowledge-domains)에 직접 쓰기
- **배포**: `docker build -t hippocampus-mcp mcp-server/` → HTTPS 엔드포인트 필요
- **환경변수**: `ES_URL`, `ES_API_KEY`, `PORT` (기본 8080)
- `.mcp` Kibana 커넥터 → Agent Builder `mcp` 타입 도구로 연결
- `MCP_SERVER_URL`이 .env에 없을 경우, 기존 커넥터 ID를 `GET /api/actions/connectors`로 조회 가능

## Elastic Workflow 실행 엔진 문제와 MCP 서버 전환

### 문제

Elastic Workflows는 ES 9.3.0에서 **Technical Preview** 상태이며, 실행 엔진에 버그가 있는 것으로 추정:

1. **등록은 성공** — `POST /api/workflows`로 YAML 등록하면 200 OK, workflow ID 발급됨
2. **실행이 즉시 실패** — `workflow` 타입 도구로 에이전트가 호출하면, 혹은 수동 트리거하면 실행 즉시 에러
3. **3개 워크플로우 모두 동일** — `remember-memory` (수동 트리거), `reflect-consolidate` (6시간 스케줄), `blindspot-report` (24시간 스케줄) 전부 같은 증상
4. **에러 내용이 불투명** — Workflow 실행 결과 API가 구체적 에러 메시지를 반환하지 않아 디버깅 불가

이 문제는 Elastic 측의 실행 엔진 버그이며, 우리 코드의 문제가 아니다. YAML 문법, 스텝 타입, 파라미터 형식을 모두 확인했고 등록 자체는 성공하므로 스키마 문제도 아니다.

### 해결: MCP 서버로 전환

핵심 기능인 `hippocampus-remember` (경험 저장)를 `workflow` 타입에서 `mcp` 타입으로 전환:

```
[Before] Agent → workflow 타입 도구 → Elastic Workflow 실행 엔진 → ES indices  (❌ 실행 실패)
[After]  Agent → mcp 타입 도구 → .mcp 커넥터 → MCP 서버 → ES REST API → ES indices  (✅ 정상)
```

### 미전환 워크플로우 (2개)

`reflect-consolidate` (에피소드→시맨틱 통합)과 `blindspot-report` (일일 사각지대 보고서)는 아직 workflow 기반이며 동작하지 않는다. YAML은 `workflows/` 디렉토리에 있으나, 실행이 필요하면 별도 MCP 도구나 cron job으로 전환해야 한다.

### Workflow YAML Format (참조용)

`workflows/` 디렉토리의 YAML은 Elastic Workflows 형식을 따른다. 향후 실행 엔진 버그 수정 시 재사용 가능:
```yaml
triggers:
  - type: manual  # not "manual: {}"
steps:
  - name: step_name
    type: elasticsearch.index  # not "action: elasticsearch.index"
    with:
      index: my-index
      document: { ... }
```

## README.md 동기화 상태

README.md는 2026-02-14 기준으로 동기화 완료. 주요 반영 항목:
- 도구 타입: recall → ES|QL, remember → MCP
- Setup: MCP 서버 배포 단계 추가, `04-mcp-remember.sh` 반영
- Dashboard: `hippocampus-dashboard-9x.ndjson` 참조
- Workflows: "Not Operational" 상태 명시, 실행 엔진 버그 설명 섹션 추가
- Technology Stack: MCP 서버 스택 추가
- Seed data: synthetic 데이터임을 명시

## E2E Testing (Playwright MCP)

Agent Builder UI 테스트는 **반드시 Playwright MCP**를 사용한다 (Chrome DevTools MCP 금지 — 브라우저 이중 실행 방지).

### Kibana Agent Builder UI 버그: 에이전트 선택 미적용

**새 대화 생성 시 에이전트가 시각적으로 선택되어 있어도 실제로는 기본 "Elastic AI Agent"가 사용됨.** 반드시 다음 패턴으로 명시적 전환 필요:

```
1. /app/agent_builder/conversations/new로 풀 페이지 네비게이션
2. 에이전트 선택 버튼 클릭 → 다이얼로그 오픈
3. "Elastic AI Agent" 클릭 (기본으로 전환)
4. 다시 에이전트 선택 버튼 클릭 → 다이얼로그 오픈
5. "Hippocampus Trust Gate" 클릭 (상태 변경 이벤트 트리거)
```

핵심: 이미 선택된 에이전트를 다시 클릭해도 상태 변경 이벤트가 발생하지 않음. 반드시 **다른 에이전트로 전환 후 다시 돌아와야** 함.

### 테스트 시나리오

| 시나리오 | 검증 포인트 |
|----------|-----------|
| Grade A + CONFLICT | recall→blindspot→contradict 순서, ⚡ CONFLICT 라벨 |
| Grade D (미경험 도메인) | 🔴 사각지대 라벨, VOID 밀도, 다른 키워드 재시도 |
| Remember (경험 저장) | hippocampus-remember 호출, SPO 구조화 |
| Grade 상승 (저장 후 재질문) | D→A/B 상승, 저장된 경험 인용 |

### 응답 대기

Agent Builder 응답은 25~45초 소요. `browser_wait_for`로 "Experience Grade" 텍스트 출현을 기다림:
```
browser_wait_for(text="Experience Grade", time=45)
```

## Dashboard

### 9.x 호환 NDJSON

`dashboard/hippocampus-dashboard-9x.ndjson`은 Kibana 9.x 네이티브 포맷으로, UI에서 직접 생성 후 export한 것이다. 10개 객체: 3 data views + 6 lens + 1 dashboard.

```bash
# Import (data view가 이미 존재해도 overwrite로 처리)
curl -X POST "${KIBANA_URL}/api/saved_objects/_import?overwrite=true" \
  -H "Authorization: ApiKey ${ES_API_KEY}" -H "kbn-xsrf: true" \
  -F file=@dashboard/hippocampus-dashboard-9x.ndjson
```

`dashboard/` 디렉토리에는 3개 파일이 있다:
- `hippocampus-dashboard-9x.ndjson` — **사용해야 할 파일** (9.x 네이티브, UI에서 export)
- `hippocampus-dashboard.ndjson` — 구버전 (8.x 포맷, 사용 금지)
- `hippocampus-dashboard-lens-only.ndjson` — Lens 전용 (디버깅용)

### 9.x 대시보드 포맷 핵심 (8.x와의 차이)

NDJSON import로 대시보드를 생성할 때 반드시 9.x 포맷을 따라야 한다:

- **패널 `panelIndex`**: UUID 형식 사용 (`panel-1` 형식 금지)
- **`embeddableConfig`**: `{}` (빈 객체. `{"enhancements": {}}` 금지)
- **패널에 `version`, `panelRefName` 필드 없음** (8.x에서 사용하던 필드)
- **Reference name**: `{panelIndex}:savedObjectRef` 형식 (`panel_` prefix 금지)
- **Lens state**: `isBucketed`, `emptyAsNull`, `colorMapping`, `sampling`, `ignoreGlobalFilters` 필드 필수
- **Lens datasourceStates**: `formBased`, `indexpattern`, `textBased` 3개 모두 필요
- **`typeMigrationVersion`**: lens=`10.1.0`, dashboard=`10.3.0`

**주의**: NDJSON으로 대시보드를 코드 생성해서 import하면 6패널 중 일부가 "Visualization type not found"로 실패하는 Kibana 9.x 버그 존재. 안전한 방법: Kibana UI에서 "Create dashboard" → "Add from library"로 직접 생성 후 export.

## Key Conventions

- All setup scripts source `.env` via `set -a; source "$ENV_FILE"; set +a`
- curl commands use direct `-H "Authorization: ApiKey ${ES_API_KEY}"` (no eval, macOS compatible)
- Seed data files are NDJSON with action+doc pairs for `_bulk` API
- `semantic_text` fields double the `_cat/indices` doc count (ELSER inference chunks); use `_count` API for actual count
- Workflow registration returns auto-generated IDs (`workflow-{uuid}`); tool's `workflow_id` must reference this, not the YAML name
- Agent tool validation: all `tool_ids` in agent config must exist before agent registration

## Agent Instructions 설계 원칙

LLM의 프로토콜 준수율을 높이기 위한 Instructions 작성 규칙:

- **MUST/NEVER 강제어** 사용 — 서술형 문장 대신 규칙 기반 구조
- **STEP 넘버링** — 도구 호출 순서를 명시적으로 강제
- **도구 description에 프로토콜 연결 정보 명시** — "Trust Gate STEP 1 필수 도구", "반드시 동시에 호출" 등
- **범용 검색 도구 제거** — `platform.core.search`가 tool_ids에 있으면 LLM이 hippocampus-recall 대신 범용 도구 선택
- **recall KEEP 필드에 entity/attribute/value 포함** — contradict 호출 시 추가 API 호출 방지 (LLM calls 8→3~4로 감소)
- **고정 출력 템플릿** — Grade 라벨을 "모든 답변의 첫 부분에 반드시 표시"로 강제

## Working Preferences

- 무언가의 작업을 대기할 때는 Exponential Backoff 방식으로 해
- 개발 작업할 때는 Agent Teams 사용을 항상 검토해
