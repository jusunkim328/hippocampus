# Hippocampus Demo Script — Trust Gate in Action

> **Duration**: ~3 minutes
> **Purpose**: Demonstrate how Trust Gate prevents LLMs from giving "confidently wrong" answers

---

## Preparation Checklist

- [ ] Elasticsearch cluster running
- [ ] Seed data loaded (`setup/` scripts executed)
- [ ] Kibana dashboard imported (`dashboard/hippocampus-dashboard-9x.ndjson`)
- [ ] Agent registered (verify `hippocampus` in Agent Builder)

---

## Act 1: The Hook (0:00 - 0:30)

### Opening Line

> "This AI was confidently wrong, costing 1 hour of additional downtime."

### Scenario

Ask a standard LLM:

> "DB connection timeouts keep recurring in the Payment service. How should we fix this?"

### Expected Response (Standard LLM)

```
To resolve DB connection timeout issues:

1. Increase connection pool size (recommend 50)
2. Adjust timeout to 30 seconds
3. Optimize HikariCP settings
4. Review database indices
```

**The Problem**:
- Based on 3-month-old information
- Doesn't know the latest fix (pool size increased from 50 → 100)
- **Delivers a confidently wrong answer**

---

## Act 2: Trust Gate ON — CONFLICT Detection (0:30 - 1:30)

### Scenario

Same question, now with Hippocampus Trust Gate:

> "DB connection timeouts keep recurring in the Payment service. How should we fix this?"

### Trust Gate Process (shown step by step)

| Step | Action | Result |
|------|--------|--------|
| **Step 1: Recall** | Semantic search across episodic-memories | 15+ matches (Grade A level) |
| **Step 2: Grade** | Assess experience density | "Grade A: sufficient evidence" |
| **Step 3: Contradict** | Check entity=`payment-service`, attribute=`db-connection-pool-size` | **CONFLICT detected!** |

### Agent Response Example

```
📊 Trust Card
├ Grade: A — 15 evidences, domain: database (DENSE)
├ Evidence: conv-db-018 (2026-02-12), conv-db-005 (2026-01-15), conv-db-012 (2025-12-20)
├ Conflict: payment-service.db-connection-pool-size: 50 → 100 (RESOLVED: latest preferred)
└ Coverage: 4/5 related attributes verified, 1 unverified (query-timeout)

⚡ CONFLICT: payment-service.db-connection-pool-size
  - [Old] 2025-11-15: "50 is optimal" (confidence: 0.7)
  - [New] 2026-02-12: "Increased 50→100, resolved" (confidence: 0.9)
  → Latest experience preferred.

## Recommended Actions
1. Increase connection pool size to 100 (based on latest experience)
2. Adjust timeout from 5s→10s (per conv-db-005)
3. Set up HikariCP metric monitoring via Prometheus

📎 References: conv-db-018, conv-db-005, conv-db-012
```

---

## Act 3: The Unknown — Honest "I Don't Know" + Execution Hold (1:30 - 2:20)

### Scenario

> "We're also seeing Redis cache latency issues. How should we handle Redis failures?"

### Trust Gate Process

| Step | Action | Result |
|------|--------|--------|
| **Step 1: Recall** | Search episodic-memories | **Only 2 matches** (insufficient) |
| **Step 2: Grade** | Assess experience density | **Grade D** |
| **Step 3: Blindspot** | `hippocampus-blindspot-targeted(domain="redis")` | density=1.5, status="SPARSE" |

### Agent Response Example

```
📊 Trust Card
├ Grade: D — 2 evidences, domain: redis (SPARSE)
├ Evidence: conv-redis-001 (2025-12-01)
├ Conflict: none
└ Coverage: 1/4 related attributes verified, 3 unverified (eviction-policy, cluster-config, sentinel-setup)

🔴 Blindspot: redis domain
  - Knowledge density: 1.5 (SPARSE)
  - Available memories: 2 (insufficient evidence)

⛔ EXECUTION HOLD — Grade D detected
This domain lacks verified organizational experience. No action recommendations will be made.

## General Information (LOW confidence — not verified against organizational experience)
1. Check Redis memory usage (review maxmemory setting)
2. Review slow log (SLOWLOG GET)
3. Check client connection count

⚠️ This answer is based on general knowledge, NOT verified organizational experience.
💡 Recommendation: Consult Redis expert (@redis-team) for confirmation.
```

---

## Act 4: Closed-Loop Growth — "Experience as an Asset" (2:20 - 3:00)

### Scenario

After resolving the incident, store the new experience:

### Remember Call

```
hippocampus-remember:
  - entity: cache-server
  - attribute: latency-fix
  - value: "Resolved by increasing Redis maxmemory from 2GB→4GB and changing eviction policy to allkeys-lru"
  - confidence: 0.85
  - category: redis
```

### Result

| Metric | Before | After |
|--------|--------|-------|
| Redis domain density | 1.5 | 2.35 |
| Status | SPARSE | SPARSE (improving) |

### Dashboard Transition

Show 4 changes on the Kibana dashboard:

1. **Knowledge Density Heatmap**: Redis area color shift (red → yellow)
2. **Experience Grade Distribution**: Grade D ratio decreasing
3. **Memory Timeline**: New memory added
4. **Trust Gate Activity**: Recall → Contradict → Blindspot call trends

### Closing Message

> **"Trust Gate: Preventing AI from being confidently wrong."**
> When evidence exists — confident answers. When it doesn't — honest disclosure. When contradictions arise — corrected responses. Experience becomes an organizational asset that grows over time.

---

## Key Messages

| # | Message | Description |
|---|---------|-------------|
| 1 | **Before** | LLMs answer every question confidently (even when wrong) |
| 2 | **After** | Trust Gate verifies against experience data before answering |
| 3 | **Growth** | As new experiences accumulate, the agent grows smarter |
| 4 | **Transparency** | Blindspots are disclosed honestly, not hidden |

---

## Presentation Tips

- Compare Act 1 and Act 2 **side by side** for maximum impact
- **Pause** at the CONFLICT detection moment — let the audience react
- **Emphasize** Act 3's "honest I don't know" and Execution Hold
- Act 4's dashboard is most impactful when showing **real-time changes**