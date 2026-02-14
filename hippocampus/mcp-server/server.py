"""Hippocampus Memory Writer — MCP Server

Elastic Workflows (Technical Preview) 실행 엔진이 동작하지 않아,
MCP (Model Context Protocol) 서버로 대체 구현.

Agent Builder의 `mcp` 타입 도구 → .mcp 커넥터 → 이 서버 → ES REST API
"""

import json
import logging
import os
from datetime import datetime, timezone

import httpx
from mcp.server.fastmcp import FastMCP

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("hippocampus-mcp")

ES_URL = os.environ["ES_URL"]
ES_API_KEY = os.environ["ES_API_KEY"]

mcp = FastMCP(
    name="hippocampus-memory-writer",
    instructions="Hippocampus 메모리 저장 서버. 에이전트가 새로운 경험을 학습할 때 사용합니다.",
    host="0.0.0.0",
    port=int(os.getenv("PORT", "8080")),
    stateless_http=True,
    json_response=True,
)


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

    # 1) episodic-memories — 원본 경험 기록
    try:
        r = await _index_document("episodic-memories", {
            "raw_text": raw_text,
            "content": raw_text,
            "timestamp": now,
            "importance": float(confidence),
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
            "confidence": float(confidence),
            "category": category,
            "first_observed": now,
            "last_updated": now,
            "update_count": 1,
        })
        results["semantic"] = {"status": "ok", "id": r.get("_id")}
    except Exception as e:
        logger.error("semantic-memories write failed: %s", e)
        results["semantic"] = {"status": "error", "message": str(e)}

    # 3) knowledge-domains — 도메인 밀도 업데이트
    try:
        r = await _index_document("knowledge-domains", {
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


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
