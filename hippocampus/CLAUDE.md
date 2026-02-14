# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

Always communicate in Korean (한국어).

## Project Overview

Hippocampus는 Elasticsearch Agent Builder 기반의 **AI Agent Guardrails** 시스템이다. LLM이 답변 전에 조직의 경험 데이터로 자기 검증하는 "Trust Gate" 패턴을 구현한다. 핵심 차별화: Mem0/Zep은 "저장+검색", Hippocampus는 **"검증+행동 변화"**.

## Setup & Deployment

```bash
# Prerequisites: Elastic Cloud Hosted (ES 9.x), ELSER v2 deployed, Agent Builder enabled
# Copy .env.example to .env and fill in ES_URL, ES_API_KEY, KIBANA_URL

# Deploy in order (each script depends on the previous)
bash setup/01-indices.sh         # 5 ES indices (ES API)
bash setup/02-ilm-policies.sh    # 2 ILM policies (ES API)
bash setup/03-tools.sh           # 5 Agent Builder tools (Kibana API)
bash setup/04-workflows.sh       # 3 Elastic Workflows (Kibana API)
bash setup/05-agent.sh           # 1 agent (Kibana API)
bash setup/06-seed-data.sh       # Seed data via _bulk (ES API)
# Dashboard: Kibana → Management → Saved Objects → Import → dashboard/hippocampus-dashboard.ndjson
```

Scripts 01-02, 06 target `ES_URL`. Scripts 03-05 target `KIBANA_URL`. Both use `ES_API_KEY` for auth. Kibana API requires `kbn-xsrf: true` header.

## Architecture

### Trust Gate Flow (query-time)

```
Query → Recall (hybrid search) → Experience Grade (A/B/C/D/CONFLICT)
  → Grade A/B: Contradict check → answer with evidence
  → Grade C: answer with "unverified" label
  → Grade D: Blindspot detection → answer with "blind spot" label
  → CONFLICT: show contradiction, prefer latest data
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
| Tools, Agents, Workflows | Kibana API | `KIBANA_URL` | `Authorization: ApiKey` + `kbn-xsrf: true` |

Kibana URL has a **different subdomain** from ES URL (found via SAML config in cluster settings, not derivable from ES URL).

### Tool Types (Kibana Agent Builder API)

- `index_search`: `configuration.pattern` (index pattern string)
- `esql`: `configuration.query` + `configuration.params` (object, not array; empty `{}` if no params)
- `workflow`: `configuration.workflow_id` (auto-generated UUID from workflow registration)

### Workflow YAML Format (Elastic Workflows, Technical Preview)

Steps use `type:` (not `action:`) with `with:` block for parameters:
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

## Key Conventions

- All setup scripts source `.env` via `set -a; source "$ENV_FILE"; set +a`
- curl commands use direct `-H "Authorization: ApiKey ${ES_API_KEY}"` (no eval, macOS compatible)
- Seed data files are NDJSON with action+doc pairs for `_bulk` API
- `semantic_text` fields double the `_cat/indices` doc count (ELSER inference chunks); use `_count` API for actual count
- Workflow registration returns auto-generated IDs (`workflow-{uuid}`); tool's `workflow_id` must reference this, not the YAML name
- Agent tool validation: all `tool_ids` in agent config must exist before agent registration

## Working Preferences

- 무언가의 작업을 대기할 때는 Exponential Backoff 방식으로 해
- 개발 작업할 때는 Agent Teams 사용을 항상 검토해
