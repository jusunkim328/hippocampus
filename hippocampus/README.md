# Hippocampus: AI Agent Guardrails

[![Elasticsearch](https://img.shields.io/badge/Elasticsearch-9.x-005571?logo=elasticsearch&logoColor=white)](https://www.elastic.co/elasticsearch)
[![Kibana](https://img.shields.io/badge/Kibana-9.x-005571?logo=kibana&logoColor=white)](https://www.elastic.co/kibana)
[![ELSER](https://img.shields.io/badge/ELSER-v2-00BFB3)](https://www.elastic.co/guide/en/machine-learning/current/ml-nlp-elser.html)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **LLMs can be confidently wrong. This agent self-verifies against organizational experience before answering.**

---

## The Problem

Large Language Models hallucinate. They give **confident but wrong** answers based on stale training data. In DevOps incident response, wrong advice doesn't just waste time — it can **worsen outages**.

Consider this scenario:
- 3 months ago, your team found that a DB connection pool size of 50 was optimal
- Last week, the team increased it to 100 to resolve recurring timeouts
- A standard LLM still confidently recommends 50 — because it doesn't know your organization's latest experience

**The cost of confidently wrong advice during an incident is measured in downtime.**

---

## The Solution: Trust Gate

Hippocampus introduces the **Trust Gate** — a pre-flight verification system that checks the agent's response against organizational experience data stored in Elasticsearch before delivering an answer.

The Trust Gate does three things:
1. **Grades** the agent's confidence based on how much relevant experience exists
2. **Detects contradictions** between old and new organizational knowledge
3. **Identifies blindspots** where the organization lacks experience — and says so honestly

### Key Differentiator

| Approach | What It Does | Example |
|----------|-------------|---------|
| **Mem0 / Zep** | Store + Retrieve | "Here are relevant memories" |
| **Hippocampus** | **Verify + Adapt** | "Conflict detected: old says X, new says Y. Using latest." |

Hippocampus doesn't just retrieve memories — it **verifies** them against each other and **adapts** the response accordingly.

---

## Architecture

```
                         ┌─────────────────────────────────────────────┐
                         │              TRUST GATE FLOW                │
                         └─────────────────────────────────────────────┘

  User Query ──►  ┌──────────┐    ┌─────────┐    ┌────────────┐    ┌───────────┐
                  │  Recall   │───►│  Grade   │───►│ Contradict │───►│ Blindspot │
                  │(ES Hybrid │    │ (A/B/C/D)│    │   Check    │    │ Detection │
                  │  Search)  │    │          │    │            │    │           │
                  └──────────┘    └─────────┘    └────────────┘    └─────┬─────┘
                                                                         │
                                                                         ▼
                                                                  ┌─────────────┐
                                                                  │   Graded     │
                                                                  │  Response    │
                                                                  └─────────────┘

                         ┌─────────────────────────────────────────────┐
                         │          MEMORY CONSOLIDATION LOOP          │
                         └─────────────────────────────────────────────┘

  New Experience ──►  ┌──────────┐    ┌──────────┐    ┌──────────┐
                      │ Remember │───►│ Reflect  │───►│ Semantic │
                      │(Episodic)│    │(Patterns)│    │(Concepts)│
                      └──────────┘    └──────────┘    └──────────┘
```

---

## Experience Grades

The Trust Gate assigns a grade to every response based on organizational experience:

| Grade | Name | Criteria | Agent Behavior |
|-------|------|----------|----------------|
| **A** | Sufficient | 3+ memories, within 30 days, consistent | Confident answer + source citations |
| **B** | Limited | 1-2 memories or older than 30 days | Answer + "Warning: Limited experience" label |
| **C** | Sparse | Insufficient evidence, only similar results | General advice + "Unverified" label + follow-up questions |
| **D** | Blindspot | No recall results | Blindspot scan + minimal general advice + "Blindspot" label + expert referral |
| **CONFLICT** | Contradiction | Conflicting values for same entity+attribute | Show conflict + prefer latest + request confirmation |

---

## Components

### Elasticsearch Indices (5)

| Index | Purpose |
|-------|---------|
| `episodic-memories` | Raw experience records from conversations and incidents |
| `semantic-memories` | Consolidated SPO triples extracted through reflection |
| `memory-associations` | Links between memories (supports, contradicts, related, supersedes) |
| `memory-access-log` | Audit trail of all Trust Gate operations (ILM 30d delete) |
| `knowledge-domains` | Domain density scores for blindspot detection |

### ILM Policies (2)

| Policy | Description |
|--------|-------------|
| `hippocampus-episodic` | Hot (0d) → Warm (7d) → Cold (30d) → Delete (90d) |
| `hippocampus-accesslog` | Hot (0d) → Delete (30d) |

### Agent Builder Tools (5)

| Tool | Type | Function |
|------|------|----------|
| `hippocampus-recall` | ES\|QL | Semantic search (ELSER v2) across episodic & semantic memories, top 5 results |
| `hippocampus-contradict` | ES\|QL | Detect conflicting values for the same entity+attribute (Knowledge Drift) |
| `hippocampus-blindspot-density` | ES\|QL | Scan all domains for knowledge density (VOID/SPARSE/DENSE) |
| `hippocampus-blindspot-targeted` | ES\|QL | Assess knowledge density for a specific domain |
| `hippocampus-remember` | MCP | Store new experience via external MCP server → 3 ES indices |

### MCP Server (`mcp-server/`)

The `hippocampus-remember` tool uses an external MCP server instead of Elastic Workflows (see [Why MCP?](#why-mcp-instead-of-elastic-workflows) below).

| Component | Detail |
|-----------|--------|
| Stack | FastMCP, Streamable HTTP, Python 3.12, httpx |
| Tool | `remember_memory(raw_text, entity, attribute, value, confidence, category)` |
| Writes to | `episodic-memories`, `semantic-memories`, `knowledge-domains` |
| Deployment | Docker → HTTPS endpoint required |

### Workflows (Not Operational)

Elastic Workflows YAML definitions exist in `workflows/` but are **not operational** due to an execution engine bug in ES 9.x Technical Preview. See [Why MCP?](#why-mcp-instead-of-elastic-workflows) for details.

| Workflow | Trigger | Status |
|----------|---------|--------|
| `remember-memory` | Manual | **Replaced by MCP server** |
| `reflect-consolidate` | Scheduled (6h) | Not operational |
| `blindspot-report` | Scheduled (24h) | Not operational |

### Agent (1)

**hippocampus-agent** — A DevOps incident copilot with the Trust Gate system prompt. Automatically verifies every response against organizational experience before answering. Uses RULE-based instructions with MUST/NEVER keywords and STEP numbering to enforce tool call order.

---

## Setup Instructions

### Prerequisites

- Elastic Cloud Hosted (ES 9.x) with ELSER v2 (`.elser-2-elastic`) deployed
- Agent Builder enabled
- Copy `.env.example` to `.env` and fill in `ES_URL`, `ES_API_KEY`, `KIBANA_URL`, `MCP_SERVER_URL`

> **Note**: `KIBANA_URL` has a **different subdomain** from `ES_URL` — it cannot be derived from ES URL. Find it via Kibana UI or cluster SAML config.

### Step-by-Step Setup

```bash
# Copy and configure environment
cp .env.example .env
# Edit .env: ES_URL, ES_API_KEY, KIBANA_URL, MCP_SERVER_URL

# 1. Deploy MCP server (backend for hippocampus-remember tool)
docker build -t hippocampus-mcp mcp-server/
# Deploy to a platform with HTTPS support, set the URL in .env as MCP_SERVER_URL

# 2. Deploy in order (each script depends on the previous)
bash setup/01-indices.sh         # 5 ES indices (ES API)
bash setup/02-ilm-policies.sh    # 2 ILM policies (ES API)
bash setup/03-tools.sh           # 4 ES|QL Agent Builder tools (Kibana API)
bash setup/04-mcp-remember.sh    # MCP connector + remember tool (Kibana API)
bash setup/05-agent.sh           # 1 agent (Kibana API)
bash setup/06-seed-data.sh       # Seed data via _bulk (ES API)

# 3. Dashboard import (Kibana 9.x native format)
curl -X POST "${KIBANA_URL}/api/saved_objects/_import?overwrite=true" \
  -H "Authorization: ApiKey ${ES_API_KEY}" -H "kbn-xsrf: true" \
  -F file=@dashboard/hippocampus-dashboard-9x.ndjson
```

> Scripts 01-02, 06 target `ES_URL`. Scripts 03-05 target `KIBANA_URL`. Both use `ES_API_KEY` for auth. All seed data is **synthetic** — no real or confidential data is used.

---

## API Integration

Hippocampus exposes three API surfaces for programmatic access:

### Converse API (Recommended)

Synchronous single-call interface. Best for automated testing and CI/CD integration.

```bash
curl -s -X POST "${KIBANA_URL}/api/agent_builder/converse" \
  -H "Authorization: ApiKey ${ES_API_KEY}" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "hippocampus", "input": "How to fix DB connection timeouts?"}'
```

Response contains `.content` with the Trust Gate graded answer.

### A2A Protocol (Agent-to-Agent)

Enables external agents to invoke Hippocampus Trust Gate as a service. Automatically exposed when the agent is registered — no additional configuration required.

```bash
# Discover agent metadata
curl -s "${KIBANA_URL}/api/agent_builder/a2a/hippocampus.json" \
  -H "Authorization: ApiKey ${ES_API_KEY}"

# Invoke via A2A
curl -s -X POST "${KIBANA_URL}/api/agent_builder/a2a/hippocampus" \
  -H "Authorization: ApiKey ${ES_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"message": {"role": "user", "parts": [{"kind": "text", "text": "Redis cache latency issue"}]}}'
```

### MCP Server

Backend for the `hippocampus-remember` tool. Stores new experiences via MCP protocol.

```bash
# Direct MCP call (for debugging)
curl -s -X POST "${MCP_SERVER_URL}/mcp" \
  -H "Content-Type: application/json" \
  -d '{"method": "tools/call", "params": {"name": "remember_memory", "arguments": {...}}}'
```

### Automated E2E Testing

Run the full Trust Gate test suite via Converse API (~2-5 seconds total, vs 25-45 seconds per query via UI):

```bash
export $(cat .env | xargs)
bash test/e2e-test.sh     # 4 scenarios: Grade A+CONFLICT, Grade D+Blindspot, Remember, Grade升
bash setup/07-verify.sh   # A2A metadata + Converse API + Agent registration check
```

---

## Demo Scenarios

The demo is structured as a 3-minute presentation in 4 acts:

| Act | Title | Duration | What Happens |
|-----|-------|----------|-------------|
| **Act 1** | Trust Gate OFF | 0:00 - 0:40 | Standard LLM gives confident but outdated advice |
| **Act 2** | The Known | 0:40 - 1:30 | Trust Gate detects contradiction, corrects answer |
| **Act 3** | The Unknown | 1:30 - 2:20 | Trust Gate identifies blindspot, flags honestly |
| **Act 4** | Growth | 2:20 - 3:00 | New experience stored, dashboard shows improvement |

See [`demo/demo-script.md`](demo/demo-script.md) for the full demo script.

---

## How It Works

### Trust Gate Flow (Query Time)

```
1. User asks: "How to fix DB connection timeouts?"
                    │
2. RECALL ──────────┤  Hybrid search (BM25 + ELSER v2)
   │                │  across episodic-memories index
   │                │  Returns: 15 relevant memories
   │
3. GRADE ───────────┤  Count memories + assess recency
   │                │  Result: Grade A (sufficient evidence)
   │
4. CONTRADICT ──────┤  Check entity="payment-service"
   │                │  attribute="db-connection-pool-size"
   │                │  Found: CONFLICT (50 vs 100)
   │                │  Resolution: prefer latest (100)
   │
5. RESPONSE ────────┤  Deliver corrected answer
                    │  with conflict disclosure
                    │  and source citations
```

### Memory Consolidation (Background)

```
1. REMEMBER ────────┤  Store raw experience
   │                │  (episodic-memories)
   │
2. REFLECT ─────────┤  Extract patterns
   │                │  across similar memories
   │
3. CONSOLIDATE ─────┤  Create/update semantic
                    │  memory entry
                    │  Update domain density
```

---

## Technology Stack

| Technology | Usage |
|-----------|-------|
| **Elasticsearch 9.x** | Primary data store, semantic search (ELSER), ILM lifecycle |
| **ELSER v2** | Semantic search via `semantic_text` field type |
| **ES\|QL** | Parameterized queries for grading, density, and contradiction detection |
| **Agent Builder** | Tool registration, agent management, Kibana API |
| **MCP (Model Context Protocol)** | External memory writer via FastMCP server (Python 3.12) |
| **Kibana 9.x** | Dashboard visualization (6 Lens panels), monitoring |

---

## Why MCP Instead of Elastic Workflows?

Elastic Workflows are in **Technical Preview** on ES 9.x and have an execution engine bug:

1. **Registration succeeds** — `POST /api/workflows` returns 200 OK with a workflow ID
2. **Execution immediately fails** — Whether triggered by an agent tool or manually, execution fails instantly
3. **All 3 workflows affected** — `remember-memory`, `reflect-consolidate`, `blindspot-report` all exhibit the same behavior
4. **Opaque errors** — The workflow execution API does not return specific error messages, making debugging impossible

This is an Elastic-side execution engine issue, not a code problem. YAML syntax, step types, and parameter formats were all verified — registration succeeds, so it's not a schema issue either.

**Solution**: The critical `hippocampus-remember` function was migrated from `workflow` type to `mcp` type:

```
[Before] Agent → workflow tool → Elastic Workflow engine → ES indices  (❌ fails)
[After]  Agent → mcp tool → .mcp connector → MCP server → ES REST API → ES indices  (✅ works)
```

The workflow YAML files are preserved in `workflows/` for potential reuse when the execution engine bug is fixed.

---

## Future Work

- **Multi-tenant support** — Isolate memories per team or organization
- **Custom grade thresholds** — Allow teams to define their own A/B/C/D criteria
- **Integration with incident management** — Auto-import from PagerDuty, OpsGenie, Jira
- **Feedback loops** — Track whether Trust Gate corrections were helpful
- **Cross-domain contradiction detection** — Detect conflicts across related domains
- **Memory decay** — Automatically reduce confidence of aging memories
- **Migrate remaining workflows** — Convert `reflect-consolidate` and `blindspot-report` to MCP tools or cron jobs

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

<p align="center">
  <b>Hippocampus</b> — Because AI agents should know what they don't know.
</p>
