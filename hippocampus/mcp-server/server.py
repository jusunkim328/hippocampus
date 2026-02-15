"""Hippocampus MCP Server — Memory Writer + Reflect + Blindspot

Elastic Workflows (Technical Preview) 실행 엔진이 동작하지 않아,
MCP (Model Context Protocol) 서버로 대체 구현.

MCP 도구 3개:
  - remember_memory: 새 경험 저장 (episodic + semantic + domain)
  - reflect_consolidate: 에피소드 → 시맨틱 통합 분석
  - generate_blindspot_report: 지식 사각지대 보고서

Agent Builder의 `mcp` 타입 도구 → .mcp 커넥터 → 이 서버 → ES REST API
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
    """'high'/'medium'/'low' 또는 숫자 문자열을 float로 변환."""
    try:
        return float(raw)
    except ValueError:
        return CONFIDENCE_MAP.get(raw.strip().lower(), 0.7)

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("hippocampus-mcp")

ES_URL = os.environ["ES_URL"]
ES_API_KEY = os.environ["ES_API_KEY"]

# 스케줄러 설정 (Docker에서 활성화)
SCHEDULER_ENABLED = os.getenv("SCHEDULER_ENABLED", "false").lower() == "true"
REFLECT_INTERVAL = int(os.getenv("REFLECT_INTERVAL_SECONDS", "21600"))   # 6시간
BLINDSPOT_INTERVAL = int(os.getenv("BLINDSPOT_INTERVAL_SECONDS", "86400"))  # 24시간

mcp = FastMCP(
    name="hippocampus-memory-writer",
    instructions="Hippocampus 메모리 서버. 경험 저장, 에피소드 통합, 사각지대 보고서를 제공합니다.",
    host="0.0.0.0",
    port=int(os.getenv("PORT", "8080")),
    stateless_http=True,
    json_response=True,
)


# ─── ES 헬퍼 함수 ─────────────────────────────────────────────

async def _index_document(index: str, document: dict) -> dict:
    """ES REST API로 문서 인덱싱."""
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
    """ES REST API 검색."""
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
    """ES REST API 집계 (size=0 기본)."""
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
    """ES REST API 벌크 업데이트."""
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


# ─── MCP 도구 1: remember_memory (기존) ───────────────────────

@mcp.tool()
async def remember_memory(
    raw_text: str,
    entity: str,
    attribute: str,
    value: str,
    confidence: str,
    category: str,
) -> str:
    """새로운 경험을 조직 지식으로 저장합니다.

    대화에서 핵심 사실을 SPO 트리플로 구조화하고
    episodic-memories, semantic-memories, knowledge-domains에 기록합니다.

    Args:
        raw_text: 원본 텍스트 (에피소드 기억)
        entity: 엔티티 이름 (예: payment-service)
        attribute: 속성 이름 (예: db-connection-pool-size)
        value: 속성 값
        confidence: 신뢰도 (0.0~1.0)
        category: 카테고리 (예: database, kubernetes)
    """
    now = datetime.now(timezone.utc).isoformat()
    results = {}

    # 입력값 정규화 — keyword 필드 대소문자 중복 방지
    entity = entity.strip().lower()
    attribute = attribute.strip().lower()
    category = category.strip().lower()

    # 1) episodic-memories — 원본 경험 기록
    try:
        r = await _index_document("episodic-memories", {
            "raw_text": raw_text,
            "content": raw_text,
            "timestamp": now,
            "importance": _parse_confidence(confidence),
            "category": category,
            "source_type": "conversation",
            "reflected": False,
        })
        results["episodic"] = {"status": "ok", "id": r.get("_id")}
    except Exception as e:
        logger.error("episodic-memories write failed: %s", e)
        results["episodic"] = {"status": "error", "message": str(e)}

    # 2) semantic-memories — SPO 트리플
    try:
        r = await _index_document("semantic-memories", {
            "content": f"{entity} {attribute} {value}",
            "entity": entity,
            "attribute": attribute,
            "value": value,
            "confidence": _parse_confidence(confidence),
            "category": category,
            "first_observed": now,
            "last_updated": now,
            "update_count": 1,
        })
        results["semantic"] = {"status": "ok", "id": r.get("_id")}
    except Exception as e:
        logger.error("semantic-memories write failed: %s", e)
        results["semantic"] = {"status": "error", "message": str(e)}

    # 3) knowledge-domains-staging — 도메인 밀도 업데이트 (staging → lookup 동기화)
    try:
        r = await _index_document("knowledge-domains-staging", {
            "domain": category,
            "last_updated": now,
        })
        results["domain"] = {"status": "ok", "id": r.get("_id")}
    except Exception as e:
        logger.error("knowledge-domains write failed: %s", e)
        results["domain"] = {"status": "error", "message": str(e)}

    ok_count = sum(1 for v in results.values() if v["status"] == "ok")
    summary = f"저장 완료 ({ok_count}/3 인덱스 성공)"
    if ok_count < 3:
        failed = [k for k, v in results.items() if v["status"] != "ok"]
        summary += f" — 실패: {', '.join(failed)}"

    return json.dumps({"summary": summary, "details": results}, ensure_ascii=False)


# ─── MCP 도구 2: reflect_consolidate ──────────────────────────

@mcp.tool()
async def reflect_consolidate() -> str:
    """에피소드 기억을 시맨틱 메모리로 통합 분석합니다.

    reflected=false인 에피소드를 수집하여 카테고리별 통계를 집계하고,
    도메인 밀도 정보를 갱신한 뒤, 에피소드 원문을 반환합니다.
    에이전트가 결과를 받아 추가 SPO 추출 등 분석을 수행할 수 있습니다.
    """
    now = datetime.now(timezone.utc).isoformat()
    results = {}

    # STEP 1: episodic-memories에서 reflected=false 검색 (최대 50건)
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
        return json.dumps({"error": f"에피소드 검색 실패: {e}"}, ensure_ascii=False)

    if not hits:
        return json.dumps({
            "summary": "통합 대상 에피소드 없음 (모두 reflected=true)",
            "episodes_processed": 0,
        }, ensure_ascii=False)

    # STEP 2: category별 그룹화 + 통계
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

    # STEP 3: semantic-memories에서 category별 집계
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
        results["semantic_stats"] = {"error": str(e)}

    # STEP 4: knowledge-domains-staging에 도메인 통계 갱신
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
            domain_updates[cat] = {"error": str(e)}

    results["domain_updates"] = domain_updates

    # STEP 5: 처리된 에피소드를 reflected=true로 마킹
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
        results["marked_reflected"] = {"error": str(e)}

    # STEP 6: episodes_for_review로 에피소드 원문 반환
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
        f"에피소드 {total_processed}건 통합 완료. "
        f"카테고리 {len(category_stats)}개: "
        + ", ".join(f"{k}({v['episode_count']}건)" for k, v in category_stats.items())
    )

    return json.dumps({
        "summary": summary,
        "episodes_processed": total_processed,
        "category_stats": category_stats,
        "domain_updates": domain_updates,
        "episodes_for_review": episodes_for_review,
    }, ensure_ascii=False)


# ─── MCP 도구 3: generate_blindspot_report ────────────────────

@mcp.tool()
async def generate_blindspot_report() -> str:
    """전체 지식 도메인의 사각지대 보고서를 생성합니다.

    모든 도메인의 density/staleness를 계산하여
    VOID/SPARSE/DENSE/Stale로 분류한 구조화된 보고서를 반환합니다.
    """
    now = datetime.now(timezone.utc).isoformat()

    # STEP 1: knowledge-domains(lookup) + knowledge-domains-staging 병합 조회
    domains = {}

    # lookup 인덱스 (정적 도메인 목록)
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

    # staging 인덱스 (최신 업데이트 반영)
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
            # staging이 lookup보다 최신이면 덮어쓰기
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

    # STEP 2: 각 도메인의 density/staleness 계산 → 분류
    report = {"void": [], "sparse": [], "dense": [], "stale": []}
    now_dt = datetime.now(timezone.utc)

    for domain_name, info in domains.items():
        density = info.get("density_score", 0)
        last_updated = info.get("last_updated")

        # staleness 체크 (30일 초과)
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
        f"VOID {len(report['void'])}개, "
        f"SPARSE {len(report['sparse'])}개, "
        f"DENSE {len(report['dense'])}개, "
        f"Stale {len(report['stale'])}개"
    )

    # STEP 3: 감사 로그 기록
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


# ─── 백그라운드 스케줄러 ──────────────────────────────────────

def _run_scheduler():
    """daemon thread에서 reflect/blindspot을 주기적으로 실행."""

    def _run_task(name, coro_fn, interval):
        """interval초마다 coro_fn을 실행하는 루프. 각 thread가 자체 event loop 사용."""
        loop = asyncio.new_event_loop()
        while True:
            time.sleep(interval)
            try:
                logger.info("[scheduler] %s 실행 시작", name)
                result = loop.run_until_complete(coro_fn())
                parsed = json.loads(result)
                logger.info("[scheduler] %s 완료: %s", name, parsed.get("summary", "ok"))
            except Exception as e:
                logger.error("[scheduler] %s 실패: %s", name, e)

    reflect_thread = threading.Thread(
        target=_run_task,
        args=("reflect_consolidate", reflect_consolidate, REFLECT_INTERVAL),
        daemon=True,
    )
    blindspot_thread = threading.Thread(
        target=_run_task,
        args=("generate_blindspot_report", generate_blindspot_report, BLINDSPOT_INTERVAL),
        daemon=True,
    )

    reflect_thread.start()
    blindspot_thread.start()
    logger.info(
        "[scheduler] 시작됨 — reflect: %ds, blindspot: %ds",
        REFLECT_INTERVAL, BLINDSPOT_INTERVAL,
    )


if __name__ == "__main__":
    if SCHEDULER_ENABLED:
        _run_scheduler()
    mcp.run(transport="streamable-http")
