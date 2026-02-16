# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hippocampus is an **AI Agent Guardrails** system built on Elasticsearch Agent Builder. It implements a "Trust Gate" pattern where the LLM self-verifies against organizational experience data before answering. Key differentiator: Mem0/Zep do "store + retrieve", Hippocampus does **"verify + behavioral change"**.

## Hackathon Context

[Elasticsearch Agent Builder Hackathon](https://elasticsearch.devpost.com/) submission.

- **Deadline**: 2026-02-27 1:00pm EST
- **Judging**: Technical Execution 30% / Impact & Innovation 30% / Demo Quality 30% / Social Sharing 10%
- **Submission Requirements**: ~300-word description + 3-min demo video + public repository (OSI license) + optional social post (@elastic_devs)
- **Data Rules**: All data must be open-source or synthetic — no confidential or personal data
- **Required Tech**: Elastic Workflows, Search, or ES|QL (at least one) — satisfied by 4 ES|QL tools


### Pre-Submission Checklist

- [ ] Switch GitHub repo to **public**
- [ ] Add **LICENSE** file (MIT)
- [ ] `.env` should only include `.env.example` (exclude real credentials)
- [ ] State in README that seed data is **synthetic**
- [ ] Write ~300-word description
- [ ] Record 3-min demo video
- [ ] Social media post (10% bonus)

## Setup & Deployment

```bash
# Prerequisites: Elastic Cloud Hosted (ES 9.x), ELSER v2 deployed, Agent Builder enabled
# Copy .env.example to .env, then set ES_URL, ES_API_KEY, KIBANA_URL, MCP_SERVER_URL

# 1. Deploy MCP server (Cloud Run — fixed HTTPS URL)
cd mcp-server
docker build --platform linux/amd64 -t your-region-docker.pkg.dev/your-gcp-project-id/hippocampus/mcp-server:latest .
docker push your-region-docker.pkg.dev/your-gcp-project-id/hippocampus/mcp-server:latest
gcloud run deploy hippocampus-mcp \
  --image your-region-docker.pkg.dev/your-gcp-project-id/hippocampus/mcp-server:latest \
  --region asia-northeast3 --project your-gcp-project-id \
  --allow-unauthenticated --memory 256Mi --cpu 1 --max-instances 3 --min-instances 0 \
  --set-secrets="ES_URL=hippocampus-es-url:latest,ES_API_KEY=hippocampus-es-api-key:latest" \
  --set-env-vars="SCHEDULER_ENABLED=false"
# Cloud Run URL (fixed): https://your-cloud-run-url.run.app
# Scheduler: 3 Cloud Scheduler jobs replace daemon threads (reflect/blindspot/sync)

# 2. Run in order (each script depends on previous steps)
bash setup/01-indices.sh         # 5 ES indices (ES API)
bash setup/02-ilm-policies.sh    # 2 ILM policies (ES API)
bash setup/03-tools.sh           # 4 ESQL Agent Builder tools (Kibana API)
bash setup/04-mcp-tools.sh       # MCP connector + 5 MCP tools (Kibana API)
bash setup/05-agent.sh           # 1 agent (Kibana API)
bash setup/06-seed-data.sh       # Seed data via _bulk (ES API)

# 3. Dashboard import (9.x native format)
curl -X POST "${KIBANA_URL}/api/saved_objects/_import?overwrite=true" \
  -H "Authorization: ApiKey ${ES_API_KEY}" -H "kbn-xsrf: true" \
  -F file=@dashboard/hippocampus-dashboard-9x.ndjson
```

Scripts 01-02, 06 target `ES_URL`. Scripts 03-05 target `KIBANA_URL`. All use `ES_API_KEY`. Kibana API requires `kbn-xsrf: true` + `x-elastic-internal-origin: Kibana` headers.

### Redeployment (when tools/agent change)

Kibana Agent Builder API returns 400/409 when creating a resource that already exists via POST. **Delete and recreate** is required:

```bash
export $(cat .env | xargs)

# Delete + re-register ESQL tools
for tool in hippocampus-recall hippocampus-contradict hippocampus-blindspot-density hippocampus-blindspot-targeted; do
  curl -X DELETE "${KIBANA_URL}/api/agent_builder/tools/${tool}" \
    -H "Authorization: ApiKey ${ES_API_KEY}" -H "kbn-xsrf: true" -H "x-elastic-internal-origin: Kibana"
done
bash setup/03-tools.sh
bash setup/04-mcp-tools.sh  # 5 MCP tools are self-deleted + recreated within the script

# Delete + re-register agent
curl -X DELETE "${KIBANA_URL}/api/agent_builder/agents/hippocampus" \
  -H "Authorization: ApiKey ${ES_API_KEY}" -H "kbn-xsrf: true" -H "x-elastic-internal-origin: Kibana"
bash setup/05-agent.sh
```

## Architecture

### Trust Gate Flow (query-time)

```
Query -> STEP 1: Recall + Blindspot (concurrent calls)
      -> STEP 2: Experience Grade determination (A/B/C/D)
      -> STEP 3: Grade A -> Contradict check
                Grade C/D -> Retry Recall with different keywords
      -> Graded Response (Grade label MUST be displayed)
```

### Data Model (5 indices)

| Index | Purpose | Notes |
|-------|---------|-------|
| `episodic-memories` | Raw experience records | `semantic_text` (ELSER v2), ILM 90d delete |
| `semantic-memories` | SPO triples (entity/attribute/value) | Permanent, `semantic_text` for search |
| `knowledge-domains` | Per-domain density scores | VOID(<1) / SPARSE(<5) / DENSE(>=5) |
| `memory-associations` | Memory links (supports/contradicts/related/supersedes) | |
| `memory-access-log` | Audit trail | ILM 30d delete |

Additionally, the `knowledge-domains-staging` index is used by the MCP server's reflect/blindspot operations (separated from the lookup index).

### Two API Surfaces

| Component | Base URL | Headers |
|-----------|----------|---------|
| Indices, ILM, Bulk data | `ES_URL` | `Authorization: ApiKey` |
| Tools, Agents, Workflows | `KIBANA_URL` | `Authorization: ApiKey` + `kbn-xsrf: true` + `x-elastic-internal-origin: Kibana` |

`KIBANA_URL` has a **different subdomain** from `ES_URL` — it cannot be derived from the ES URL.

### Agent Builder Tools (11: 9 custom + 2 platform)

| Tool | Type | Trust Gate Role |
|------|------|----------------|
| `hippocampus-recall` | esql | STEP 1 — Semantic experience search (top 5, includes external_refs) |
| `hippocampus-blindspot-targeted` | esql | STEP 1 — Domain density lookup |
| `hippocampus-contradict` | esql | STEP 3 — Knowledge Drift detection |
| `hippocampus-blindspot-density` | esql | Full domain density scan |
| `hippocampus-remember` | mcp | Store new experience (3 indices + optional external_refs) |
| `hippocampus-reflect` | mcp | Episode consolidation (category aggregation -> domain update) |
| `hippocampus-blindspot-report` | mcp | Full blindspot report (VOID/SPARSE/DENSE/Stale) |
| `hippocampus-export` | mcp | Knowledge base NDJSON export (backup/team sharing) |
| `hippocampus-import` | mcp | Knowledge base NDJSON import (duplicate CONFLICT detection) |
| `platform.core.execute_esql` | built-in | General data queries outside memory indices |
| `platform.core.list_indices` | built-in | Index listing |

`platform.core.search` was intentionally **removed** — prevents LLM from choosing generic search over recall.

### Tool Types (Kibana Agent Builder API)

| Type | Configuration Fields | Notes |
|------|---------------------|-------|
| `esql` | `query` + `params` (object, not array; empty `{}` if no params) | |
| `mcp` | `connector_id` + `tool_name` | Calls external MCP server via `.mcp` connector |
| `index_search` | `pattern` (index pattern string) | |
| `workflow` | `workflow_id` | **Not usable** — execution engine bug |

### MCP Server (`mcp-server/`)

Backend for 6 MCP tools. FastMCP + Streamable HTTP + Python 3.12 + httpx.

**Tools:**
- `remember_memory(raw_text, entity, attribute, value, confidence, category, external_refs="")` — Store experience (episodic + semantic + staging across 3 indices + audit log). Attach Jira/Runbook URLs via external_refs.
- `reflect_consolidate()` — Episode consolidation (reflected=false -> category aggregation -> domain update)
- `generate_blindspot_report()` — Blindspot report (VOID/SPARSE/DENSE/Stale)
- `export_knowledge_base()` — Full knowledge base NDJSON export (search_after pagination)
- `import_knowledge_base(ndjson)` — NDJSON import (CONFLICT detection on semantic entity+attribute duplicates)
- `sync_knowledge_domains()` — staging -> lookup sync (delete -> recreate -> bulk). Cloud Scheduler only.

**Environment Variables:**
| Variable | Default | Description |
|----------|---------|-------------|
| `ES_URL` | (required) | Elasticsearch URL |
| `ES_API_KEY` | (required) | API Key |
| `PORT` | `8080` | Server port |
| `SCHEDULER_ENABLED` | `false` | Enable background scheduler (set false on Cloud Run) |
| `REFLECT_INTERVAL_SECONDS` | `21600` (6h) | Reflect interval (local only) |
| `BLINDSPOT_INTERVAL_SECONDS` | `86400` (24h) | Blindspot interval (local only) |
| `SYNC_INTERVAL_SECONDS` | `3600` (1h) | knowledge-domains sync interval (local only) |
| `MCP_AUTH_TOKEN` | (optional) | Bearer token auth. **Note: Kibana `.mcp` connector does not forward Authorization headers, so this is unusable in Cloud Run production** |

**Deployment (Cloud Run):**
- GCP Project: `your-gcp-project-id`, Region: `asia-northeast3`
- Cloud Run URL: `https://your-cloud-run-url.run.app`
- Secrets: Secret Manager (`hippocampus-es-url`, `hippocampus-es-api-key`) — MCP_AUTH_TOKEN removed due to connector incompatibility
- `.mcp` Kibana connector connects to Cloud Run URL (connector ID: `your-mcp-connector-id`)

**Scheduler (Cloud Scheduler — replaces daemon threads on Cloud Run):**
| Job | Schedule (KST) | Tool |
|-----|---------------|------|
| `hippocampus-reflect` | `0 */6 * * *` (every 6 hours) | `reflect_consolidate` |
| `hippocampus-blindspot` | `0 4 * * *` (daily at 4am) | `generate_blindspot_report` |
| `hippocampus-sync` | `0 * * * *` (hourly) | `sync_knowledge_domains` |

Cloud Scheduler calls require `Accept: application/json` + `Content-Type: application/json` headers. (Authorization header is configured in Cloud Scheduler but ignored by the server since MCP_AUTH_TOKEN is not set)

**Local Development (Docker Compose):**
`SCHEDULER_ENABLED=true docker compose up -d` — Uses daemon thread scheduler locally, no auth.

**Audit Log:** `remember_memory`, `export_knowledge_base`, `import_knowledge_base` calls are automatically recorded in `memory-access-log`.

## Known Issues & Pitfalls

### Elastic Workflow Execution Engine Bug

Registration succeeds in ES 9.x Technical Preview, but execution immediately fails. All 3 workflows have been fully migrated to MCP.

```
[Before] Agent -> workflow tool -> Elastic Workflow engine -> ES  (fails)
[After]  Agent -> mcp tool -> .mcp connector -> MCP server -> ES  (works)
```

### ES Data Type Caveats

- `importance` field may be returned as string from ES -> always convert with `float()`
- `semantic_text` field causes `_cat/indices` to show 2x doc count (ELSER inference chunks) -> use `_count` API for actual count

### macOS Shell Compatibility

- `head -n -1` does not work on macOS -> use `sed '$d'`
- Nested `$()` inside `python3 -c` in shell scripts causes syntax errors -> use `os.environ` + temp file pattern

### Kibana Agent Builder UI Bug: Agent Selection Not Applied

In a new conversation, the agent may appear visually selected but the default "Elastic AI Agent" is actually used. You **must switch to a different agent and then switch back** to trigger the state change event:

```
1. Navigate to /app/agent_builder/conversations/new
2. Agent selection -> click "Elastic AI Agent" (switch to default)
3. Agent selection again -> click "Hippocampus Trust Gate"
```

### Kibana `.mcp` Connector Auth Incompatibility

Kibana `.mcp` connector does not forward `Authorization` headers set in `secrets.headers` to the MCP server. Therefore, app-level Bearer token auth does not work with Kibana Agent Builder integration. In Cloud Run production, `MCP_AUTH_TOKEN` env var is not set and the service runs with `--allow-unauthenticated`.

### Cloud Run Redeployment Procedure

To redeploy after code changes:

```bash
cd mcp-server
docker build --platform linux/amd64 -t your-region-docker.pkg.dev/your-gcp-project-id/hippocampus/mcp-server:latest .
docker push your-region-docker.pkg.dev/your-gcp-project-id/hippocampus/mcp-server:latest
gcloud run deploy hippocampus-mcp \
  --image your-region-docker.pkg.dev/your-gcp-project-id/hippocampus/mcp-server:latest \
  --region asia-northeast3 --project your-gcp-project-id
```

> **Note**: ngrok dependency was removed with Cloud Run migration. Cloud Run URL is fixed, so connector updates are not needed.

### 9.x Dashboard NDJSON Format

Code-generated NDJSON imports frequently fail with "Visualization type not found". **Safe approach: Create directly in Kibana UI, then export.**

Required rules:
- `panelIndex`: Must be UUID format (`panel-1` is not allowed)
- `embeddableConfig`: `{}` (`{"enhancements":{}}` is not allowed)
- Panels must not have `version`/`panelRefName` fields
- Lens state requires: `isBucketed`, `emptyAsNull`, `colorMapping`, `sampling`, `ignoreGlobalFilters`
- Lens datasourceStates: all 3 are required — `formBased`, `indexpattern`, `textBased`

## E2E Testing

### API Tests (Recommended — 2-5 seconds)

```bash
export $(cat .env | xargs)
bash test/e2e-test.sh     # 10 scenarios: Grade A+CONFLICT, Grade D, Remember, Reflect, Blindspot, Grade Upgrade, Export/Import, MCP Health, External Refs, Import CONFLICT
bash setup/07-verify.sh   # A2A metadata + Converse API + Agent registration check
```

### Direct MCP Server Testing

```bash
MCP_URL=https://your-cloud-run-url.run.app/mcp

# tools/list
curl -s -X POST "$MCP_URL" -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# reflect
curl -s -X POST "$MCP_URL" -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"reflect_consolidate","arguments":{}}}'

# blindspot report
curl -s -X POST "$MCP_URL" -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"generate_blindspot_report","arguments":{}}}'
```

### UI Testing (Chrome DevTools MCP / Playwright MCP)

Agent Builder UI tests use Chrome DevTools MCP or Playwright MCP. Response takes 25-45 seconds -> `wait_for(text="Experience Grade", timeout=60000)`.

Agent selection bug workaround is required — in a new conversation, always switch to a different agent first, then switch back to Hippocampus. Agent dropdown options may not be exposed in the a11y tree -> use `evaluate_script` for text matching and click.

## Project Structure

```
├── agent/hippocampus-agent.json   # Agent definition (instructions + tool_ids)
├── tools/*.json                   # 4 ESQL tool definitions (recall, contradict, blindspot-density, blindspot-targeted)
├── mcp-server/
│   ├── server.py                  # FastMCP server (6 tools + auth + scheduler)
│   ├── Dockerfile                 # Python 3.12-slim
│   └── requirements.txt           # fastmcp, httpx, uvicorn
├── setup/
│   ├── 01-indices.sh              # ES indices creation
│   ├── 02-ilm-policies.sh         # ILM policies
│   ├── 03-tools.sh                # Register 4 ESQL tools
│   ├── 04-mcp-tools.sh            # Register MCP connector + 5 tools
│   ├── 05-agent.sh                # Agent registration
│   ├── 06-seed-data.sh            # Seed data
│   ├── 07-verify.sh               # Verification script
│   └── 08-sync-domains.sh         # Domain sync
├── test/e2e-test.sh               # E2E 10 scenarios
├── dashboard/*.ndjson             # Kibana dashboard
├── seed-data/*.ndjson             # Seed data (synthetic)
├── docker-compose.yml             # MCP server Docker Compose
├── .env.example                   # Environment variable template
└── .env                           # Actual environment variables (gitignored)
```

## Agent Instructions Design Principles

- **MUST/NEVER imperatives** — Rule-based instead of descriptive
- **STEP numbering** — Explicitly enforces tool call order
- **Protocol linkage in tool descriptions** — e.g., "Trust Gate STEP 1 required tool"
- **Generic search tool removal** — LLM chooses recall over `platform.core.search` when it's available
- **recall KEEP fields include entity/attribute/value** — Prevents extra API calls during contradict (8 -> 3-4 calls)
- **Fixed output template** — Grade label is "MUST be displayed at the beginning of every response"
- **RULE 5 Auto-Record Protocol** — 4 triggers (incident report, config change, problem resolution, new fact confirmation) + Post-Answer Protocol (self-check for unsaved information after answering)

## Working Preferences

- Use Exponential Backoff when waiting for operations
- Always consider using Agent Teams for development tasks
