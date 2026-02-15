"""Hippocampus MCP Server — Memory Writer + Reflect + Blindspot

Replacement for Elastic Workflows (Technical Preview) execution engine
which is non-functional, implemented as an MCP (Model Context Protocol) server.

MCP Tools (6):
  - remember_memory: Store new experience (episodic + semantic + domain)
  - reflect_consolidate: Consolidate episodes → semantic analysis
  - generate_blindspot_report: Knowledge blindspot report
  - export_knowledge_base: Export knowledge base as NDJSON
  - import_knowledge_base: Import knowledge base from NDJSON (CONFLICT detection)
  - sync_knowledge_domains: Sync staging → lookup domain indices

Agent Builder `mcp` type tool → .mcp connector → this server → ES REST API
"""

import asyncio
import json
import logging
import os
import threading
import time
from collections import defaultdict
from datetime import datetime, timezone
from typing import Union

import httpx
from mcp.server.fastmcp import FastMCP

CONFIDENCE_MAP = {"high": 0.9, "medium": 0.7, "low": 0.5}


def _parse_confidence(raw: str) -> float:
    """Convert 'high'/'medium'/'low' or numeric string to float."""
    try:
        return float(raw)
    except ValueError:
        return CONFIDENCE_MAP.get(raw.strip().lower(), 0.7)

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("hippocampus-mcp")

ES_URL = os.environ["ES_URL"]
ES_API_KEY = os.environ["ES_API_KEY"]

# Scheduler settings (enabled in Docker)
SCHEDULER_ENABLED = os.getenv("SCHEDULER_ENABLED", "false").lower() == "true"
REFLECT_INTERVAL = int(os.getenv("REFLECT_INTERVAL_SECONDS", "21600"))   # 6 hours
BLINDSPOT_INTERVAL = int(os.getenv("BLINDSPOT_INTERVAL_SECONDS", "86400"))  # 24 hours
SYNC_INTERVAL = int(os.getenv("SYNC_INTERVAL_SECONDS", "3600"))  # 1 hour

mcp = FastMCP(
    name="hippocampus-memory-writer",
    instructions="Hippocampus memory server. Provides experience storage, episode consolidation, and blindspot reporting.",
    host="0.0.0.0",
    port=int(os.getenv("PORT", "8080")),
    stateless_http=True,
    json_response=True,
)


ALLOWED_INDICES = frozenset({
    "episodic-memories", "semantic-memories", "knowledge-domains",
    "knowledge-domains-staging", "memory-associations", "memory-access-log",
})

def _validate_index(index: str) -> str:
    if index not in ALLOWED_INDICES:
        raise ValueError(f"Index '{index}' is not in the allowed list")
    return index

MAX_FIELD_LENGTH = 256
MAX_VALUE_LENGTH = 2000
MAX_RAW_TEXT_LENGTH = 10000
MAX_EXTERNAL_REFS = 10

MAX_IMPORT_LINES = 1000
MAX_IMPORT_BYTES = 5 * 1024 * 1024  # 5MB


def _safe_error(e: Exception) -> str:
    error_type = type(e).__name__
    if isinstance(e, httpx.HTTPStatusError):
        return f"{error_type}: HTTP {e.response.status_code}"
    return error_type


# ─── ES Helper Functions ─────────────────────────────────────────────

async def _index_document(index: str, document: dict) -> dict:
    """Index a document via ES REST API."""
    _validate_index(index)
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            f"{ES_URL}/{index}/_doc",
            headers={
                "Authorization": f"ApiKey {ES_API_KEY}",
                "Content-Type": "application/json",
            },
            content=json.dumps(document),
        )
        resp.raise_for_status()
        return resp.json()


async def _es_search(index: str, body: dict) -> dict:
    """Search via ES REST API."""
    _validate_index(index)
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            f"{ES_URL}/{index}/_search",
            headers={
                "Authorization": f"ApiKey {ES_API_KEY}",
                "Content-Type": "application/json",
            },
            content=json.dumps(body),
        )
        resp.raise_for_status()
        return resp.json()


async def _es_aggregate(index: str, body: dict) -> dict:
    """Aggregate via ES REST API (size=0 default)."""
    _validate_index(index)
    if "size" not in body:
        body["size"] = 0
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            f"{ES_URL}/{index}/_search",
            headers={
                "Authorization": f"ApiKey {ES_API_KEY}",
                "Content-Type": "application/json",
            },
            content=json.dumps(body),
        )
        resp.raise_for_status()
        return resp.json()


async def _es_update_by_query(index: str, body: dict) -> dict:
    """Bulk update via ES REST API."""
    _validate_index(index)
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            f"{ES_URL}/{index}/_update_by_query",
            headers={
                "Authorization": f"ApiKey {ES_API_KEY}",
                "Content-Type": "application/json",
            },
            content=json.dumps(body),
        )
        resp.raise_for_status()
        return resp.json()


async def _es_delete_index(index: str) -> int:
    """Delete an ES index. Returns HTTP status code."""
    _validate_index(index)
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.delete(
            f"{ES_URL}/{index}",
            headers={"Authorization": f"ApiKey {ES_API_KEY}"},
        )
        return resp.status_code


async def _es_create_index(index: str, body: dict) -> int:
    """Create an ES index. Returns HTTP status code."""
    _validate_index(index)
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.put(
            f"{ES_URL}/{index}",
            headers={
                "Authorization": f"ApiKey {ES_API_KEY}",
                "Content-Type": "application/json",
            },
            content=json.dumps(body),
        )
        return resp.status_code


async def _es_bulk(body: str) -> dict:
    """Call ES _bulk API."""
    async with httpx.AsyncClient(timeout=60) as client:
        resp = await client.post(
            f"{ES_URL}/_bulk",
            headers={
                "Authorization": f"ApiKey {ES_API_KEY}",
                "Content-Type": "application/x-ndjson",
            },
            content=body,
        )
        resp.raise_for_status()
        return resp.json()


# ─── MCP Tool 1: remember_memory ───────────────────────

@mcp.tool()
async def remember_memory(
    raw_text: str,
    entity: str,
    attribute: str,
    value: str,
    confidence: str,
    category: str,
    external_refs: str = "",
) -> str:
    """Store a new experience as organizational knowledge.

    Structures key facts from conversation as SPO triples and
    records them in episodic-memories, semantic-memories, and knowledge-domains.

    Args:
        raw_text: Original text (episodic memory)
        entity: Entity name (e.g., payment-service)
        attribute: Attribute name (e.g., db-connection-pool-size)
        value: Attribute value
        confidence: Confidence level (0.0~1.0)
        category: Category (e.g., database, kubernetes)
        external_refs: External reference URLs (comma-separated). e.g., "https://jira.example.com/ISSUE-123, https://wiki.example.com/runbook"
    """
    now = datetime.now(timezone.utc).isoformat()
    results = {}

    # Normalize input — prevent keyword field case duplicates
    entity = entity.strip().lower()
    attribute = attribute.strip().lower()
    category = category.strip().lower()

    # Parse external_refs — comma-separated URLs → list
    refs_list = [r.strip() for r in external_refs.split(",") if r.strip()] if external_refs else []

    # Validate input lengths
    if len(raw_text) > MAX_RAW_TEXT_LENGTH:
        return json.dumps({"error": f"raw_text exceeds {MAX_RAW_TEXT_LENGTH} characters"})
    if len(entity) > MAX_FIELD_LENGTH or len(attribute) > MAX_FIELD_LENGTH:
        return json.dumps({"error": f"entity/attribute exceeds {MAX_FIELD_LENGTH} characters"})
    if len(value) > MAX_VALUE_LENGTH:
        return json.dumps({"error": f"value exceeds {MAX_VALUE_LENGTH} characters"})
    if len(category) > MAX_FIELD_LENGTH:
        return json.dumps({"error": f"category exceeds {MAX_FIELD_LENGTH} characters"})
    if len(refs_list) > MAX_EXTERNAL_REFS:
        return json.dumps({"error": f"external_refs exceeds {MAX_EXTERNAL_REFS} items"})

    # 1) episodic-memories — raw experience record
    try:
        ep_doc = {
            "raw_text": raw_text,
            "content": raw_text,
            "timestamp": now,
            "importance": _parse_confidence(confidence),
            "category": category,
            "source_type": "conversation",
            "reflected": False,
        }
        if refs_list:
            ep_doc["external_refs"] = refs_list
        r = await _index_document("episodic-memories", ep_doc)
        results["episodic"] = {"status": "ok", "id": r.get("_id")}
    except Exception as e:
        logger.error("episodic-memories write failed: %s", e)
        results["episodic"] = {"status": "error", "message": _safe_error(e)}

    # 2) semantic-memories — SPO triples
    try:
        sem_doc = {
            "content": f"{entity} {attribute} {value}",
            "entity": entity,
            "attribute": attribute,
            "value": value,
            "confidence": _parse_confidence(confidence),
            "category": category,
            "first_observed": now,
            "last_updated": now,
            "update_count": 1,
        }
        if refs_list:
            sem_doc["external_refs"] = refs_list
        r = await _index_document("semantic-memories", sem_doc)
        results["semantic"] = {"status": "ok", "id": r.get("_id")}
    except Exception as e:
        logger.error("semantic-memories write failed: %s", e)
        results["semantic"] = {"status": "error", "message": _safe_error(e)}

    # 3) knowledge-domains-staging — domain density update (staging → lookup sync)
    try:
        r = await _index_document("knowledge-domains-staging", {
            "domain": category,
            "last_updated": now,
        })
        results["domain"] = {"status": "ok", "id": r.get("_id")}
    except Exception as e:
        logger.error("knowledge-domains write failed: %s", e)
        results["domain"] = {"status": "error", "message": _safe_error(e)}

    ok_count = sum(1 for v in results.values() if v["status"] == "ok")
    summary = f"Saved successfully ({ok_count}/3 indices)"
    if ok_count < 3:
        failed = [k for k, v in results.items() if v["status"] != "ok"]
        summary += f" — failed: {', '.join(failed)}"

    # 4) Audit log entry (memory-access-log)
    try:
        await _index_document("memory-access-log", {
            "timestamp": now,
            "action": "remember",
            "query": f"{entity} {attribute}",
            "experience_grade": "NEW",
            "relevance_score": _parse_confidence(confidence),
            "blindspot_triggered": False,
        })
    except Exception as e:
        logger.error("remember: audit log write failed: %s", e)

    return json.dumps({"summary": summary, "details": results}, ensure_ascii=False)


# ─── MCP Tool 2: reflect_consolidate ──────────────────────────

@mcp.tool()
async def reflect_consolidate() -> str:
    """Consolidate episodic memories into semantic memory analysis.

    Collects episodes with reflected=false, aggregates statistics by category,
    updates domain density information, and returns episode texts.
    The agent can then perform additional analysis such as SPO extraction.
    """
    now = datetime.now(timezone.utc).isoformat()
    results = {}

    # STEP 1: Search episodic-memories for reflected=false (max 50)
    try:
        episodic_resp = await _es_search("episodic-memories", {
            "query": {"term": {"reflected": False}},
            "size": 50,
            "sort": [{"timestamp": "desc"}],
            "_source": ["raw_text", "content", "category", "importance", "timestamp"],
        })
        hits = episodic_resp.get("hits", {}).get("hits", [])
    except Exception as e:
        logger.error("reflect: episodic search failed: %s", e)
        return json.dumps({"error": f"Episodic search failed: {_safe_error(e)}"}, ensure_ascii=False)

    if not hits:
        return json.dumps({
            "summary": "No episodes to consolidate (all reflected=true)",
            "episodes_processed": 0,
        }, ensure_ascii=False)

    # STEP 2: Group by category + statistics
    categories = defaultdict(lambda: {"count": 0, "total_importance": 0.0, "episodes": []})
    episode_ids = []

    for hit in hits:
        src = hit["_source"]
        cat = src.get("category", "unknown")
        raw_imp = src.get("importance", 0.5)
        imp = float(raw_imp) if not isinstance(raw_imp, (int, float)) else raw_imp
        categories[cat]["count"] += 1
        categories[cat]["total_importance"] += imp
        categories[cat]["episodes"].append({
            "id": hit["_id"],
            "content": src.get("content", src.get("raw_text", "")),
            "importance": imp,
            "timestamp": src.get("timestamp"),
        })
        episode_ids.append(hit["_id"])

    category_stats = {}
    for cat, data in categories.items():
        category_stats[cat] = {
            "episode_count": data["count"],
            "avg_importance": round(data["total_importance"] / data["count"], 2),
        }

    results["category_stats"] = category_stats

    # STEP 3: Aggregate by category from semantic-memories
    try:
        sem_agg = await _es_aggregate("semantic-memories", {
            "aggs": {
                "by_category": {
                    "terms": {"field": "category", "size": 50},
                    "aggs": {
                        "avg_confidence": {"avg": {"field": "confidence"}},
                    },
                }
            },
        })
        sem_buckets = sem_agg.get("aggregations", {}).get("by_category", {}).get("buckets", [])
        semantic_stats = {}
        for b in sem_buckets:
            semantic_stats[b["key"]] = {
                "doc_count": b["doc_count"],
                "avg_confidence": round(b["avg_confidence"]["value"] or 0, 2),
            }
        results["semantic_stats"] = semantic_stats
    except Exception as e:
        logger.error("reflect: semantic aggregation failed: %s", e)
        results["semantic_stats"] = {"error": _safe_error(e)}

    # STEP 4: Update domain statistics in knowledge-domains-staging
    domain_updates = {}
    for cat, stats in category_stats.items():
        sem = results.get("semantic_stats", {}).get(cat, {})
        memory_count = sem.get("doc_count", 0) + stats["episode_count"]
        avg_conf = sem.get("avg_confidence", stats["avg_importance"])
        density_score = round(memory_count * avg_conf, 2)

        if density_score >= 5:
            status = "DENSE"
        elif density_score >= 1:
            status = "SPARSE"
        else:
            status = "VOID"

        try:
            await _index_document("knowledge-domains-staging", {
                "domain": cat,
                "memory_count": memory_count,
                "avg_confidence": avg_conf,
                "density_score": density_score,
                "status": status,
                "last_updated": now,
            })
            domain_updates[cat] = {"status": status, "density_score": density_score}
        except Exception as e:
            logger.error("reflect: domain update failed for %s: %s", cat, e)
            domain_updates[cat] = {"error": _safe_error(e)}

    results["domain_updates"] = domain_updates

    # STEP 5: Mark processed episodes as reflected=true
    try:
        update_resp = await _es_update_by_query("episodic-memories", {
            "query": {"ids": {"values": episode_ids}},
            "script": {
                "source": "ctx._source.reflected = true",
                "lang": "painless",
            },
        })
        results["marked_reflected"] = update_resp.get("updated", 0)
    except Exception as e:
        logger.error("reflect: update_by_query failed: %s", e)
        results["marked_reflected"] = {"error": _safe_error(e)}

    # STEP 6: Return episode texts for review
    episodes_for_review = []
    for cat, data in categories.items():
        for ep in data["episodes"]:
            episodes_for_review.append({
                "category": cat,
                "content": ep["content"],
                "importance": ep["importance"],
            })

    total_processed = len(episode_ids)
    summary = (
        f"Consolidated {total_processed} episodes. "
        f"{len(category_stats)} categories: "
        + ", ".join(f"{k}({v['episode_count']})" for k, v in category_stats.items())
    )

    return json.dumps({
        "summary": summary,
        "episodes_processed": total_processed,
        "category_stats": category_stats,
        "domain_updates": domain_updates,
        "episodes_for_review": episodes_for_review,
    }, ensure_ascii=False)


# ─── MCP Tool 3: generate_blindspot_report ────────────────────

@mcp.tool()
async def generate_blindspot_report() -> str:
    """Generate a blindspot report for all knowledge domains.

    Calculates density/staleness for all domains and returns a structured
    report with VOID/SPARSE/DENSE/Stale classifications.
    """
    now = datetime.now(timezone.utc).isoformat()

    # STEP 1: Merge query from knowledge-domains (lookup) + staging
    domains = {}

    # lookup index (static domain list)
    try:
        lookup_resp = await _es_search("knowledge-domains", {
            "query": {"match_all": {}},
            "size": 100,
            "_source": ["domain", "memory_count", "avg_confidence", "density_score", "last_updated"],
        })
        for hit in lookup_resp.get("hits", {}).get("hits", []):
            src = hit["_source"]
            domain_name = src.get("domain", "unknown")
            domains[domain_name] = {
                "source": "lookup",
                "memory_count": src.get("memory_count", 0),
                "avg_confidence": src.get("avg_confidence", 0),
                "density_score": src.get("density_score", 0),
                "last_updated": src.get("last_updated"),
            }
    except Exception as e:
        logger.error("blindspot: knowledge-domains lookup failed: %s", e)

    # staging index (reflects latest updates)
    try:
        staging_agg = await _es_aggregate("knowledge-domains-staging", {
            "aggs": {
                "by_domain": {
                    "terms": {"field": "domain", "size": 100},
                    "aggs": {
                        "latest": {"max": {"field": "last_updated"}},
                        "avg_density": {"avg": {"field": "density_score"}},
                        "avg_conf": {"avg": {"field": "avg_confidence"}},
                        "total_memory": {"sum": {"field": "memory_count"}},
                    },
                }
            },
        })
        for b in staging_agg.get("aggregations", {}).get("by_domain", {}).get("buckets", []):
            domain_name = b["key"]
            # Overwrite if staging is newer than lookup
            if domain_name not in domains or (b["latest"]["value_as_string"] or "") > (domains.get(domain_name, {}).get("last_updated") or ""):
                density = b["avg_density"]["value"] if b["avg_density"]["value"] is not None else 0
                domains[domain_name] = {
                    "source": "staging",
                    "memory_count": int(b["total_memory"]["value"] or 0),
                    "avg_confidence": round(b["avg_conf"]["value"] or 0, 2),
                    "density_score": round(density, 2),
                    "last_updated": b["latest"].get("value_as_string"),
                }
    except Exception as e:
        logger.error("blindspot: knowledge-domains-staging aggregation failed: %s", e)

    # STEP 2: Calculate density/staleness per domain → classify
    report = {"void": [], "sparse": [], "dense": [], "stale": []}
    now_dt = datetime.now(timezone.utc)

    for domain_name, info in domains.items():
        density = info.get("density_score", 0)
        last_updated = info.get("last_updated")

        # Staleness check (over 30 days)
        is_stale = False
        if last_updated:
            try:
                lu_dt = datetime.fromisoformat(last_updated.replace("Z", "+00:00"))
                days_since = (now_dt - lu_dt).days
                is_stale = days_since > 30
            except (ValueError, TypeError):
                pass

        entry = {
            "domain": domain_name,
            "density_score": density,
            "memory_count": info.get("memory_count", 0),
            "avg_confidence": info.get("avg_confidence", 0),
            "last_updated": last_updated,
        }

        if is_stale:
            entry["days_since_update"] = days_since
            report["stale"].append(entry)
        elif density < 1:
            report["void"].append(entry)
        elif density < 5:
            report["sparse"].append(entry)
        else:
            report["dense"].append(entry)

    summary = (
        f"VOID {len(report['void'])}, "
        f"SPARSE {len(report['sparse'])}, "
        f"DENSE {len(report['dense'])}, "
        f"Stale {len(report['stale'])}"
    )

    # STEP 3: Audit log entry
    try:
        await _index_document("memory-access-log", {
            "action": "blindspot_report",
            "timestamp": now,
            "details": summary,
        })
    except Exception as e:
        logger.error("blindspot: audit log write failed: %s", e)

    return json.dumps({
        "summary": summary,
        "report": report,
    }, ensure_ascii=False)


# ─── MCP Tool 4: export_knowledge_base ────────────────────────

@mcp.tool()
async def export_knowledge_base() -> str:
    """Export the entire organizational knowledge base as NDJSON.

    Converts all documents from episodic-memories, semantic-memories,
    and knowledge-domains into NDJSON with _type tags.
    Can be used for Git-based team sharing or backup.
    """
    now = datetime.now(timezone.utc).isoformat()
    lines: list[str] = []
    counts = {"episodic": 0, "semantic": 0, "domain": 0}

    async def _scan_index(index: str, source_fields: list[str], doc_type: str):
        """Scan all documents using search_after pagination."""
        search_after = None
        while True:
            body: dict = {
                "query": {"match_all": {}},
                "size": 100,
                "sort": [{"_doc": "asc"}],
                "_source": source_fields,
            }
            if search_after:
                body["search_after"] = search_after

            resp = await _es_search(index, body)
            hits = resp.get("hits", {}).get("hits", [])
            if not hits:
                break

            for hit in hits:
                doc = hit["_source"]
                doc["_type"] = doc_type
                lines.append(json.dumps(doc, ensure_ascii=False))
                counts[doc_type] += 1
                search_after = hit["sort"]

    # 1) episodic-memories (exclude content — semantic_text, regenerated on import)
    try:
        await _scan_index(
            "episodic-memories",
            ["raw_text", "category", "importance", "timestamp", "source_type", "external_refs"],
            "episodic",
        )
    except Exception as e:
        logger.error("export: episodic scan failed: %s", e)

    # 2) semantic-memories (exclude content)
    try:
        await _scan_index(
            "semantic-memories",
            ["entity", "attribute", "value", "confidence", "category",
             "first_observed", "last_updated", "update_count", "external_refs"],
            "semantic",
        )
    except Exception as e:
        logger.error("export: semantic scan failed: %s", e)

    # 3) knowledge-domains (lookup)
    try:
        await _scan_index(
            "knowledge-domains",
            ["domain", "memory_count", "avg_confidence", "density_score", "status", "last_updated"],
            "domain",
        )
    except Exception as e:
        logger.error("export: domain scan failed: %s", e)

    ndjson = "\n".join(lines)
    total = sum(counts.values())
    summary = (
        f"Export complete: episodic {counts['episodic']}, "
        f"semantic {counts['semantic']}, "
        f"domain {counts['domain']} (total {total})"
    )

    # Audit log
    try:
        await _index_document("memory-access-log", {
            "timestamp": now,
            "action": "export",
            "details": summary,
        })
    except Exception as e:
        logger.error("export: audit log failed: %s", e)

    return json.dumps({
        "summary": summary, "ndjson": ndjson, "counts": counts,
    }, ensure_ascii=False)


# ─── MCP Tool 5: import_knowledge_base ────────────────────────

@mcp.tool()
async def import_knowledge_base(ndjson: str) -> str:
    """Import a knowledge base from NDJSON format.

    Parses NDJSON exported by export_knowledge_base and stores documents
    in episodic-memories, semantic-memories, and knowledge-domains-staging.
    Marks as CONFLICT when semantic entity+attribute duplicates existing data.

    Args:
        ndjson: NDJSON format string. Each line is a JSON object with _type field.
    """
    now = datetime.now(timezone.utc).isoformat()

    # Validate import size
    if len(ndjson) > MAX_IMPORT_BYTES:
        return json.dumps({"error": f"Import data exceeds {MAX_IMPORT_BYTES // (1024*1024)}MB limit"})
    if ndjson.count('\n') + 1 > MAX_IMPORT_LINES:
        return json.dumps({"error": f"Import data exceeds {MAX_IMPORT_LINES} lines limit"})

    imported = {"episodic": 0, "semantic": 0, "domain": 0}
    conflicts: list[dict] = []
    errors: list[str] = []

    # Parse and classify line by line
    docs: dict[str, list[dict]] = {"episodic": [], "semantic": [], "domain": []}
    for i, line in enumerate(ndjson.strip().split("\n")):
        line = line.strip()
        if not line:
            continue
        try:
            doc = json.loads(line)
            doc_type = doc.pop("_type", None)
            if doc_type in docs:
                docs[doc_type].append(doc)
            else:
                errors.append(f"line {i+1}: unknown _type '{doc_type}'")
        except json.JSONDecodeError as e:
            errors.append(f"line {i+1}: JSON parse error: {e}")

    # 1) episodic-memories — bulk insert
    if docs["episodic"]:
        bulk_lines = []
        for doc in docs["episodic"]:
            doc["content"] = doc.get("raw_text", "")  # for semantic_text regeneration
            doc.setdefault("reflected", False)
            doc.setdefault("timestamp", now)
            bulk_lines.append(json.dumps({"index": {"_index": "episodic-memories"}}))
            bulk_lines.append(json.dumps(doc, ensure_ascii=False))
        try:
            resp = await _es_bulk("\n".join(bulk_lines) + "\n")
            imported["episodic"] = sum(
                1 for item in resp.get("items", [])
                if item.get("index", {}).get("status") in (200, 201)
            )
        except Exception as e:
            errors.append(f"episodic bulk: {_safe_error(e)}")

    # 2) semantic-memories — bulk insert after duplicate check
    if docs["semantic"]:
        bulk_lines = []
        for doc in docs["semantic"]:
            entity = doc.get("entity", "").strip().lower()
            attribute = doc.get("attribute", "").strip().lower()
            value = doc.get("value", "")
            doc["entity"] = entity
            doc["attribute"] = attribute
            doc["content"] = f"{entity} {attribute} {value}"  # for semantic_text regeneration
            doc.setdefault("last_updated", now)

            # Duplicate check (entity+attribute)
            try:
                dup_resp = await _es_search("semantic-memories", {
                    "query": {"bool": {"must": [
                        {"term": {"entity": entity}},
                        {"term": {"attribute": attribute}},
                    ]}},
                    "size": 1,
                    "_source": ["value", "last_updated"],
                })
                dup_hits = dup_resp.get("hits", {}).get("hits", [])
                if dup_hits:
                    existing_value = dup_hits[0]["_source"].get("value", "")
                    if existing_value != value:
                        conflicts.append({
                            "entity": entity,
                            "attribute": attribute,
                            "existing_value": existing_value,
                            "imported_value": value,
                        })
            except Exception:
                pass  # Proceed with save even if duplicate check fails

            bulk_lines.append(json.dumps({"index": {"_index": "semantic-memories"}}))
            bulk_lines.append(json.dumps(doc, ensure_ascii=False))

        try:
            resp = await _es_bulk("\n".join(bulk_lines) + "\n")
            imported["semantic"] = sum(
                1 for item in resp.get("items", [])
                if item.get("index", {}).get("status") in (200, 201)
            )
        except Exception as e:
            errors.append(f"semantic bulk: {_safe_error(e)}")

    # 3) knowledge-domains-staging — bulk insert
    if docs["domain"]:
        bulk_lines = []
        for doc in docs["domain"]:
            doc.setdefault("last_updated", now)
            bulk_lines.append(json.dumps({"index": {"_index": "knowledge-domains-staging"}}))
            bulk_lines.append(json.dumps(doc, ensure_ascii=False))
        try:
            resp = await _es_bulk("\n".join(bulk_lines) + "\n")
            imported["domain"] = sum(
                1 for item in resp.get("items", [])
                if item.get("index", {}).get("status") in (200, 201)
            )
        except Exception as e:
            errors.append(f"domain bulk: {_safe_error(e)}")

    total = sum(imported.values())
    summary = (
        f"Import complete: {total} docs "
        f"(episodic {imported['episodic']}, "
        f"semantic {imported['semantic']}, "
        f"domain {imported['domain']})"
    )
    if conflicts:
        summary += f", CONFLICT {len(conflicts)} found"
    if errors:
        summary += f", {len(errors)} error(s)"

    # Audit log
    try:
        await _index_document("memory-access-log", {
            "timestamp": now,
            "action": "import",
            "details": summary,
        })
    except Exception as e:
        logger.error("import: audit log failed: %s", e)

    return json.dumps({
        "summary": summary,
        "imported": imported,
        "conflicts": conflicts,
        "errors": errors,
    }, ensure_ascii=False)


# ─── Domain Sync (staging → lookup) ─────────────────────────

# knowledge-domains index schema (index.mode: lookup)
KNOWLEDGE_DOMAINS_SCHEMA = {
    "settings": {"index.mode": "lookup"},
    "mappings": {
        "properties": {
            "domain": {"type": "keyword"},
            "memory_count": {"type": "integer"},
            "avg_confidence": {"type": "float"},
            "last_updated": {"type": "date"},
            "density_score": {"type": "float"},
            "status": {"type": "keyword"},
        }
    },
}


@mcp.tool()
async def sync_knowledge_domains() -> str:
    """Sync knowledge-domains-staging → knowledge-domains (lookup).

    Aggregates from staging → deletes lookup → recreates → bulk insert.
    Called periodically by Cloud Scheduler.
    """
    # 1. Aggregate by domain from staging
    try:
        agg_resp = await _es_aggregate("knowledge-domains-staging", {
            "aggs": {
                "by_domain": {
                    "terms": {"field": "domain", "size": 100},
                    "aggs": {
                        "latest": {"max": {"field": "last_updated"}},
                        "avg_conf": {"avg": {"field": "avg_confidence"}},
                        "max_count": {"max": {"field": "memory_count"}},
                        "max_density": {"max": {"field": "density_score"}},
                    },
                }
            },
        })
    except Exception as e:
        msg = f"sync: staging aggregation failed: {_safe_error(e)}"
        logger.error("sync: staging aggregation failed: %s", e)
        return json.dumps({"error": msg}, ensure_ascii=False)

    buckets = agg_resp.get("aggregations", {}).get("by_domain", {}).get("buckets", [])
    if not buckets:
        return json.dumps({"summary": "No data in staging — skipping sync"}, ensure_ascii=False)

    # 2. Delete lookup index
    del_status = await _es_delete_index("knowledge-domains")
    logger.info("sync: knowledge-domains deleted HTTP %d", del_status)

    # 3. Recreate in lookup mode
    create_status = await _es_create_index("knowledge-domains", KNOWLEDGE_DOMAINS_SCHEMA)
    if create_status not in (200, 201):
        msg = f"sync: knowledge-domains recreation failed HTTP {create_status}"
        logger.error(msg)
        return json.dumps({"error": msg}, ensure_ascii=False)

    # 4. Bulk insert aggregation results
    bulk_lines = []
    for b in buckets:
        domain = b["key"]
        mem_count = int(b["max_count"]["value"] or 0)
        avg_conf = round(b["avg_conf"]["value"] or 0, 2)
        density = round(b["max_density"]["value"] or 0, 2)
        last_upd = b["latest"].get("value_as_string", "")

        status = "DENSE"
        if density < 1.0:
            status = "VOID"
        elif density < 5.0:
            status = "SPARSE"

        bulk_lines.append(json.dumps({"index": {"_index": "knowledge-domains"}}))
        bulk_lines.append(json.dumps({
            "domain": domain,
            "memory_count": mem_count,
            "avg_confidence": avg_conf,
            "last_updated": last_upd,
            "density_score": density,
            "status": status,
        }))

    bulk_body = "\n".join(bulk_lines) + "\n"
    try:
        bulk_resp = await _es_bulk(bulk_body)
        errors = bulk_resp.get("errors", False)
        summary = f"Sync complete: {len(buckets)} domains"
        if errors:
            summary += " (some bulk errors occurred)"
        logger.info("sync: %s", summary)
        return json.dumps({"summary": summary, "domains_synced": len(buckets)}, ensure_ascii=False)
    except Exception as e:
        msg = f"sync: bulk insert failed: {_safe_error(e)}"
        logger.error("sync: bulk insert failed: %s", e)
        return json.dumps({"error": msg}, ensure_ascii=False)


# ─── Background Scheduler ──────────────────────────────────────

def _run_scheduler():
    """Run reflect/blindspot/sync periodically in daemon threads."""

    def _run_task(name, coro_fn, interval):
        """Loop that runs coro_fn every interval seconds. Each thread uses its own event loop."""
        loop = asyncio.new_event_loop()
        while True:
            time.sleep(interval)
            try:
                logger.info("[scheduler] %s starting", name)
                result = loop.run_until_complete(coro_fn())
                parsed = json.loads(result)
                logger.info("[scheduler] %s complete: %s", name, parsed.get("summary", "ok"))
            except Exception as e:
                logger.error("[scheduler] %s failed: %s", name, e)

    def _run_reflect_then_sync(interval):
        """Run reflect followed by automatic sync. Separate thread."""
        loop = asyncio.new_event_loop()
        while True:
            time.sleep(interval)
            try:
                logger.info("[scheduler] reflect_consolidate starting")
                result = loop.run_until_complete(reflect_consolidate())
                parsed = json.loads(result)
                logger.info("[scheduler] reflect_consolidate complete: %s", parsed.get("summary", "ok"))

                # Auto sync after reflect
                logger.info("[scheduler] post-reflect sync_knowledge_domains starting")
                sync_result = loop.run_until_complete(sync_knowledge_domains())
                sync_parsed = json.loads(sync_result)
                logger.info("[scheduler] sync complete: %s", sync_parsed.get("summary", "ok"))
            except Exception as e:
                logger.error("[scheduler] reflect+sync failed: %s", e)

    reflect_thread = threading.Thread(
        target=_run_reflect_then_sync,
        args=(REFLECT_INTERVAL,),
        daemon=True,
    )
    blindspot_thread = threading.Thread(
        target=_run_task,
        args=("generate_blindspot_report", generate_blindspot_report, BLINDSPOT_INTERVAL),
        daemon=True,
    )
    sync_thread = threading.Thread(
        target=_run_task,
        args=("sync_knowledge_domains", sync_knowledge_domains, SYNC_INTERVAL),
        daemon=True,
    )

    reflect_thread.start()
    blindspot_thread.start()
    sync_thread.start()
    logger.info(
        "[scheduler] started — reflect: %ds, blindspot: %ds, sync: %ds",
        REFLECT_INTERVAL, BLINDSPOT_INTERVAL, SYNC_INTERVAL,
    )


MCP_AUTH_TOKEN = os.getenv("MCP_AUTH_TOKEN")
CLOUD_RUN_URL = os.getenv("CLOUD_RUN_URL", "")


def _verify_auth(auth_header: str) -> bool:
    """Verify Bearer token or Google OIDC ID Token."""
    if not auth_header.startswith("Bearer "):
        return False
    token = auth_header[7:]

    # 1) Static Bearer token match
    if MCP_AUTH_TOKEN and token == MCP_AUTH_TOKEN:
        return True

    # 2) Google OIDC ID Token verification (for Cloud Scheduler)
    if CLOUD_RUN_URL:
        try:
            from google.oauth2 import id_token as google_id_token
            from google.auth.transport import requests as google_requests
            google_id_token.verify_oauth2_token(
                token, google_requests.Request(), audience=CLOUD_RUN_URL,
            )
            return True
        except Exception as e:
            logger.warning("OIDC verification failed: %s", e)

    return False


if __name__ == "__main__":
    if SCHEDULER_ENABLED:
        _run_scheduler()

    if MCP_AUTH_TOKEN or CLOUD_RUN_URL:
        import uvicorn
        from starlette.responses import JSONResponse as _JSONResp

        inner_app = mcp.streamable_http_app()

        async def auth_app(scope, receive, send):
            if scope["type"] == "http":
                headers = dict(scope.get("headers", []))
                auth = headers.get(b"authorization", b"").decode()
                if not _verify_auth(auth):
                    resp = _JSONResp(
                        {"jsonrpc": "2.0", "id": None,
                         "error": {"code": -32000, "message": "Unauthorized"}},
                        status_code=401,
                    )
                    await resp(scope, receive, send)
                    return
            await inner_app(scope, receive, send)

        logger.info("Auth enabled — Bearer token or OIDC required")
        uvicorn.run(
            auth_app,
            host="0.0.0.0",
            port=int(os.getenv("PORT", "8080")),
        )
    else:
        mcp.run(transport="streamable-http")
