# Hippocampus — AI Agent Guardrails with Trust Gate

## The Problem

LLMs hallucinate. During DevOps incidents, they deliver **confidently wrong** answers based on stale training data. Three months ago your team found a DB connection pool size of 50 was optimal — last week they increased it to 100 to fix recurring timeouts. A standard LLM still confidently recommends 50. **Wrong advice during an outage costs real downtime.**

## The Solution: Trust Gate

Hippocampus introduces the **Trust Gate** — a pre-flight verification system that checks every AI response against organizational experience stored in Elasticsearch before delivering an answer.

The Trust Gate:
1. **Grades** confidence (A/B/C/D) based on relevant evidence depth
2. **Detects contradictions** between old and new organizational knowledge (CONFLICT)
3. **Identifies blindspots** where experience is lacking — and says so honestly
4. **Holds execution** when evidence is insufficient (Grade D/CONFLICT → ⛔ EXECUTION HOLD)

Every response begins with a **Trust Card** — a structured verification summary showing grade, evidence, conflicts, and coverage at a glance.

## Key Differentiator: "Verify + Adapt" vs "Store + Retrieve"

Most memory systems (Mem0, Zep) store and retrieve. Hippocampus **verifies** memories against each other and **adapts** agent behavior accordingly. When contradictions exist, it resolves them. When blindspots exist, it discloses them. When evidence is insufficient, it holds action recommendations.

## Elastic Technologies Used

- **ES|QL** with LOOKUP JOIN for real-time domain density assessment during Trust Gate
- **ELSER v2** for semantic search across episodic and semantic memories
- **ILM policies** for automatic memory lifecycle management (episodic 90d, access log 30d)
- **Agent Builder** for tool registration, agent management, and Converse/A2A APIs
- **A2A Protocol** enabling other agents to invoke Trust Gate as a verification service

## Architecture

9 custom tools (4 ES|QL + 5 MCP) + 2 platform tools power the Trust Gate flow:
- **Query path**: Recall → Grade → Contradict → Blindspot → Graded Response
- **Growth path**: Remember → Reflect → Consolidate → Domain Density Update

## What I Liked Building

The ES|QL LOOKUP JOIN elegance — a single query enriches recall results with domain density metadata, enabling the Trust Gate to assess both content relevance and domain coverage simultaneously. Instruction engineering to reliably enforce tool call sequences was equally satisfying.

## Challenges

- **Elastic Workflows execution engine bug** (Technical Preview, ES 9.x) — registration succeeds but execution fails immediately. Pivoted all 3 workflows to MCP server tools.
- **Kibana `.mcp` connector auth incompatibility** — the connector doesn't forward Authorization headers to MCP servers. Resolved by disabling auth on Cloud Run.

## Security & Governance

**Current**: Audit logging for all memory operations, source tracking with external_refs, ILM-based automatic data aging, input normalization (lowercase entity/attribute).

**Planned**: Configurable grade thresholds per team, input validation middleware, role-based memory access, memory decay scoring.
