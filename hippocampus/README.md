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
| `hippocampus-recall` | Index Search | Hybrid search (BM25 + ELSER) across episodic & semantic memories |
| `hippocampus-contradict` | ES\|QL | Detect conflicting values for the same entity+attribute |
| `hippocampus-blindspot-density` | ES\|QL | Scan all domains for knowledge density (VOID/SPARSE/DENSE) |
| `hippocampus-blindspot-targeted` | ES\|QL | Assess knowledge density for a specific domain |
| `hippocampus-remember` | Workflow | Store new experience as episodic + semantic memory |

### Workflows (3)

| Workflow | Trigger | Description |
|----------|---------|-------------|
| `remember-memory` | Manual | Store new experience in episodic + semantic memories |
| `reflect-consolidate` | Scheduled (6h) | Consolidate episodic memories into semantic knowledge |
| `blindspot-report` | Scheduled (24h) | Generate daily knowledge blindspot report |

### Agent (1)

**hippocampus-agent** — An AI agent with the Trust Gate system prompt that automatically verifies every response against organizational experience before answering.

---

## Setup Instructions

### Prerequisites

- Elastic Cloud Hosted (ES 9.x) with ELSER v2 (`.elser-2-elastic`) deployed
- Agent Builder enabled
- Copy `.env.example` to `.env` and fill in `ES_URL`, `ES_API_KEY`, `KIBANA_URL`

> **Note**: `KIBANA_URL` has a **different subdomain** from `ES_URL` — it cannot be derived from ES URL. Find it via Kibana UI or cluster SAML config.

### Step-by-Step Setup

```bash
# Copy and configure environment
cp .env.example .env
# Edit .env: ES_URL, ES_API_KEY, KIBANA_URL

# Deploy in order (each script depends on the previous)
bash setup/01-indices.sh         # 5 ES indices (ES API)
bash setup/02-ilm-policies.sh    # 2 ILM policies (ES API)
bash setup/03-tools.sh           # 5 Agent Builder tools (Kibana API)
bash setup/04-workflows.sh       # 3 Elastic Workflows (Kibana API)
bash setup/05-agent.sh           # 1 agent (Kibana API)
bash setup/06-seed-data.sh       # Seed data via _bulk (ES API)

# Dashboard: Kibana → Management → Saved Objects → Import → dashboard/hippocampus-dashboard.ndjson
```

> Scripts 01-02, 06 target `ES_URL`. Scripts 03-05 target `KIBANA_URL`. Both use `ES_API_KEY` for auth.

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
| **Elasticsearch 9.x** | Primary data store, hybrid search, ILM lifecycle |
| **ELSER v2** | Semantic search for memory recall |
| **ES\|QL** | Aggregation queries for grading and density |
| **Agent Builder** | Tool registration, workflow orchestration, agent management |
| **Kibana 9.x** | Dashboard visualization, monitoring |

---

## Future Work

- **Multi-tenant support** — Isolate memories per team or organization
- **Custom grade thresholds** — Allow teams to define their own A/B/C/D criteria
- **Integration with incident management** — Auto-import from PagerDuty, OpsGenie, Jira
- **Feedback loops** — Track whether Trust Gate corrections were helpful
- **Cross-domain contradiction detection** — Detect conflicts across related domains
- **Memory decay** — Automatically reduce confidence of aging memories

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

<p align="center">
  <b>Hippocampus</b> — Because AI agents should know what they don't know.
</p>
