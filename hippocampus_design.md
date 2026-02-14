# Hippocampus: The AI Agent That Knows What It Doesn't Know

> ES를 AI 에이전트의 해마(hippocampus)로 활용하는 영구 기억 시스템.
> 기억하고, 회상하고, 통합하고, 모순을 잡고, 잊고, **자기 무지를 안다.**

---

## 1. 왜 Hippocampus인가 — 뇌과학 매핑

실제 해마(hippocampus)의 6가지 기능이 ES 기능과 1:1 대응된다:

| 해마 기능 | 도구 | ES 기능 |
|----------|------|---------|
| 기억 부호화 (encoding) | **Remember** | Index API, semantic_text |
| 기억 인출 (retrieval) | **Recall** | Index Search, RRF hybrid |
| 기억 응고 (consolidation) | **Reflect** | Scheduled Workflow + ai.agent |
| 패턴 분리 (pattern separation) | **Contradict** | ES\|QL JOIN/GROUP/FILTER |
| 시냅스 가지치기 (synaptic pruning) | **Forget** | ILM hot→warm→cold→delete |
| **새로움 탐지 (novelty detection)** | **Blindspot** | **ES\|QL STATS + _score 분석** |

Blindspot은 해마의 "novelty detection" 기능 — 익숙하지 않은 자극을 감지하는 것 — 을 구현한 것이다. 기존 메모리 시스템(Mem0, LangChain, Zep)에 **없는 기능**이며, 이것이 Hippocampus의 핵심 차별화 포인트다.

---

## 2. 6대 도구 설계

### 2.1 Remember — 기억 저장

**트리거**: 에이전트가 중요한 정보를 인식할 때

**프로세스**:
1. 대화에서 핵심 사실 추출
2. SPO 트리플로 구조화: `(entity, attribute, value, time, confidence)`
3. 카테고리 자동 태깅 (Blindspot 추적용)
4. Episodic Memory 인덱스에 저장 (원문 + 구조화)
5. knowledge-domains 인덱스의 해당 카테고리 카운트 업데이트

**예시**:
```
입력: "Payment 서비스의 DB 커넥션 풀을 50에서 100으로 증설해서 타임아웃을 해결했다"
→ episodic-memories에 원문 저장
→ semantic-memories에 SPO 저장:
   entity: "payment-service"
   attribute: "db-connection-pool-fix"
   value: "50→100 증설로 타임아웃 해결"
   confidence: 0.9
   category: "database"
   source_conversation_id: "conv_abc123"
```

### 2.2 Recall — 기억 검색

**트리거**: 에이전트가 과거 경험이 필요할 때

**프로세스**:
1. 쿼리를 semantic_text로 하이브리드 검색 (ELSER + BM25 via RRF)
2. 결과에 가중 스코어 적용:
   ```
   recall_score = semantic_similarity × 0.4
               + recency_decay × 0.3
               + access_frequency × 0.15
               + importance × 0.15
   ```
3. **max_score 체크** → Blindspot 자동 트리거 여부 판단
4. memory-access-log에 접근 기록
5. 크로스-컨텍스트 결과가 있으면 Serendipity 힌트로 표시

**Blindspot 자동 연동**:
- 상위 5개 결과의 max_score < 0.3 → Blindspot 자동 호출
- 에이전트가 "이 영역에 대한 기억이 부족합니다"라고 먼저 경고

### 2.3 Contradict — 모순 탐지

**트리거**: Remember 시 기존 기억과의 충돌 체크, 또는 명시적 호출

**프로세스**:
1. 새 SPO의 (entity, attribute)로 기존 semantic-memories 검색
2. ES|QL로 동일 (entity, attribute)에 다른 value가 존재하는지 확인:
   ```esql
   FROM semantic-memories
   | WHERE entity == "payment-service"
     AND attribute == "db-connection-pool-size"
   | STATS value_count = COUNT_DISTINCT(value),
           values = VALUES(value),
           times = VALUES(last_updated)
   | WHERE value_count > 1
   ```
3. 모순 발견 시: 시간순 정렬 + confidence 비교 → 어느 쪽이 최신/신뢰할 수 있는지 제시
4. memory-associations에 "contradicts" 관계 기록

**데모 장면**:
> "이전 기억: 'DB 커넥션 풀은 50이 최적' (3개월 전, confidence 0.7)
> 새 기억: '50→100 증설로 해결' (오늘, confidence 0.9)
> ⚠️ 모순 감지: 커넥션 풀 최적값이 변경되었습니다. 기존 기억을 업데이트할까요?"

### 2.4 Reflect — 기억 통합/압축

**트리거**: Elastic Workflow (Scheduled — 매 6시간, 또는 Alert — 에피소드 50건 초과)

**프로세스** (Workflow YAML):
1. 트리거 조건 확인 (시간 또는 임계치)
2. 최근 미통합 episodic memories 수집
3. ai.agent 스텝으로 LLM 호출:
   - 관련 에피소드 클러스터링
   - 핵심 교훈/패턴 추출
   - 기존 semantic-memories와 병합 또는 신규 생성
4. 통합된 에피소드에 "reflected: true" 플래그
5. knowledge-domains 밀도 점수 재계산

**데모 장면**:
> "3건의 DB 타임아웃 인시던트를 통합합니다:
> → 새 의미 기억: 'payment-service DB 타임아웃은 주로 금요일 오후 트래픽 증가 시 발생하며, 커넥션 풀 증설이 효과적'"

### 2.5 Forget — 망각 곡선

**트리거**: ILM 정책 자동 실행

**ILM 정책 설계**:
```
hippocampus-ilm-policy:
  hot:    0-7일   — 원문 전체 유지, 빠른 검색
  warm:   7-30일  — 레플리카 축소, 여전히 검색 가능
  cold:   30-90일 — 읽기 전용, 필요시에만 접근
  delete: 90일+   — 단, Reflect로 승격된 semantic memory는 보존
```

**핵심 규칙**: 삭제 전 반드시 Reflect 실행 → 핵심 사실이 semantic-memories에 보존된 것을 확인한 후에만 episodic 원문 삭제.

**데모 장면**:
> "90일 된 인시던트 상세 로그 3건 → 핵심 교훈은 이미 의미 기억으로 승격됨 → 원문 안전 삭제
> 저장 공간: 2.3MB → 0.1MB (95% 감소), 핵심 지식: 100% 보존"

### 2.6 Blindspot — 자기 무지 탐지 ⭐

**트리거**: Recall 시 자동 (low score) + 명시적 호출 (전체 진단)

**3가지 탐지 방식**:

#### (A) 쿼리 시점 갭 탐지 (Reactive)
Recall 결과의 유사도 점수를 분석:
```
max_score >= 0.7  → 🟢 "이 영역에 충분한 경험이 있습니다"
max_score 0.3~0.7 → 🟡 "제한된 경험입니다. 신뢰도를 낮춰 참고하세요"
max_score < 0.3   → 🔴 "⚠️ 사각지대: 이 영역의 기억이 거의 없습니다"
```

#### (B) 카테고리 밀도 분석 (Proactive)
```esql
FROM knowledge-domains
| STATS memory_count = SUM(memory_count),
        avg_conf = AVG(avg_confidence),
        oldest = MIN(last_updated)
  BY domain
| EVAL density = memory_count * avg_conf,
       staleness_days = DATE_DIFF("day", oldest, NOW()),
       status = CASE(
         density < 1.0, "🔴 VOID",
         density < 5.0, "🟡 SPARSE",
         "🟢 DENSE"
       )
| SORT density ASC
```

#### (C) 시간적 사각지대 탐지
```esql
FROM semantic-memories
| STATS last_update = MAX(last_updated),
        count = COUNT(*)
  BY category
| WHERE DATE_DIFF("day", last_update, NOW()) > 60
| EVAL warning = CONCAT("⚠️ ", category, ": 마지막 업데이트 ",
                        TO_STRING(DATE_DIFF("day", last_update, NOW())),
                        "일 전 — 지식이 오래되었을 수 있음")
| SORT last_update ASC
```

**데모 장면** (핵심 와우 모먼트):
> 사용자: "Redis 클러스터가 장애입니다"
> 에이전트 Recall → 결과 max_score: 0.12
> 에이전트: "⚠️ **사각지대 감지**: Redis 관련 기억 밀도 0.04 (vs Database 0.87).
> 이 영역은 제 경험이 거의 없어 판단의 신뢰도가 낮습니다.
> Redis 전문가나 공식 문서를 우선 참조하시기를 권합니다.
> 제가 할 수 있는 것: 일반적인 패턴 기반 추론 (신뢰도: LOW)"
>
> [인시던트 해결 후]
> 에이전트: "이 Redis 장애 경험을 기억했습니다.
> Redis 밀도: 0.04 → 0.15로 개선. 다음엔 더 나은 도움을 드릴 수 있습니다."

---

## 3. ES 인덱스 아키텍처

### 3.1 episodic-memories (일화 기억)
```json
{
  "mappings": {
    "properties": {
      "content": { "type": "semantic_text" },
      "raw_text": { "type": "text" },
      "conversation_id": { "type": "keyword" },
      "user_id": { "type": "keyword" },
      "timestamp": { "type": "date" },
      "importance": { "type": "float" },
      "access_count": { "type": "integer" },
      "last_accessed": { "type": "date" },
      "category": { "type": "keyword" },
      "source_type": { "type": "keyword" },
      "reflected": { "type": "boolean" },
      "metadata": { "type": "object" }
    }
  }
}
```
- ILM 정책 적용: `hippocampus-ilm-policy`
- semantic_text: ELSER 자동 임베딩

### 3.2 semantic-memories (의미 기억 — SPO 트리플)
```json
{
  "mappings": {
    "properties": {
      "content": { "type": "semantic_text" },
      "entity": { "type": "keyword" },
      "attribute": { "type": "keyword" },
      "value": { "type": "text" },
      "confidence": { "type": "float" },
      "category": { "type": "keyword" },
      "source_conversation_ids": { "type": "keyword" },
      "first_observed": { "type": "date" },
      "last_updated": { "type": "date" },
      "update_count": { "type": "integer" }
    }
  }
}
```
- ILM 미적용 (영구 보존)
- Contradict의 핵심 데이터 소스

### 3.3 memory-associations (기억 연결)
```json
{
  "mappings": {
    "properties": {
      "source_memory_id": { "type": "keyword" },
      "target_memory_id": { "type": "keyword" },
      "association_type": { "type": "keyword" },
      "strength": { "type": "float" },
      "created_at": { "type": "date" }
    }
  }
}
```
- association_type: "supports" | "contradicts" | "related" | "supersedes"

### 3.4 memory-access-log (접근 감사 로그)
```json
{
  "mappings": {
    "properties": {
      "timestamp": { "type": "date" },
      "memory_id": { "type": "keyword" },
      "action": { "type": "keyword" },
      "query": { "type": "text" },
      "conversation_id": { "type": "keyword" },
      "relevance_score": { "type": "float" },
      "blindspot_triggered": { "type": "boolean" }
    }
  }
}
```
- action: "recall" | "remember" | "reflect" | "contradict" | "forget" | "blindspot"
- ILM 적용: 30일 후 삭제

### 3.5 knowledge-domains (지식 영역 밀도 — Blindspot용)
```json
{
  "mappings": {
    "properties": {
      "domain": { "type": "keyword" },
      "category": { "type": "keyword" },
      "memory_count": { "type": "integer" },
      "avg_confidence": { "type": "float" },
      "last_updated": { "type": "date" },
      "density_score": { "type": "float" },
      "status": { "type": "keyword" }
    }
  }
}
```
- Reflect Workflow가 주기적으로 재계산
- Blindspot의 Proactive 분석 데이터 소스

---

## 4. Workflow 설계

### 4.1 Memory Consolidation Workflow (Reflect)
```yaml
name: hippocampus-reflect
description: 파편화된 일화 기억을 의미 기억으로 통합
trigger:
  - schedule:
      interval: 6h
  - alert:
      condition: "episodic-memories에 reflected=false인 문서 >= 50"
steps:
  - id: gather
    action: search
    index: episodic-memories
    query: { "term": { "reflected": false } }
    sort: [{ "timestamp": "desc" }]
    size: 100

  - id: consolidate
    action: ai.agent
    input: "다음 일화 기억들을 분석하여 핵심 교훈과 패턴을 SPO 형태로 추출하라: {{gather.results}}"

  - id: store
    action: index
    index: semantic-memories
    document: "{{consolidate.output}}"

  - id: mark-reflected
    action: update
    index: episodic-memories
    query: { "ids": "{{gather.ids}}" }
    body: { "reflected": true }

  - id: update-domains
    action: ai.agent
    input: "knowledge-domains 인덱스의 카테고리별 memory_count와 density_score를 재계산하라"
```

### 4.2 Blindspot Report Workflow
```yaml
name: hippocampus-blindspot-report
description: 주기적 지식 사각지대 보고
trigger:
  - schedule:
      interval: 24h
steps:
  - id: analyze
    action: esql
    query: |
      FROM knowledge-domains
      | EVAL density = memory_count * avg_confidence,
             staleness = DATE_DIFF("day", last_updated, NOW())
      | WHERE density < 3.0 OR staleness > 30
      | SORT density ASC

  - id: report
    action: ai.agent
    input: "사각지대 분석 결과를 리포트로 작성하라: {{analyze.results}}"
```

---

## 5. 3분 데모 시나리오: DevOps 인시던트 코파일럿

### Act 1: The Known (0:00 - 1:00)

**상황**: 모니터링 알림 — "payment-service DB connection timeout"

```
사용자: "Payment 서비스에서 DB 커넥션 타임아웃이 발생했어"

에이전트: [Recall 실행 — max_score: 0.85 🟢]
"3건의 유사 인시던트를 기억하고 있습니다:

 1. 2024-03-15: 같은 서비스, 커넥션 풀 고갈 → 50→100 증설로 해결 (confidence: 0.9)
 2. 2024-06-22: 유사 증상, 실제 원인은 느린 쿼리 → 인덱스 추가로 해결 (confidence: 0.85)
 3. 2024-09-10: 커넥션 리크, 코드 수정 필요 (confidence: 0.8)

[Contradict 실행]
⚠️ 단, 3월 인시던트 당시 CPU 사용률은 95%였으나 현재는 23%입니다.
같은 원인(커넥션 풀 고갈)이 아닐 가능성이 높습니다.
→ 6월 케이스(느린 쿼리)나 9월 케이스(커넥션 리크)를 우선 확인하시길 권합니다."
```

### Act 2: The Unknown (1:00 - 2:00) ⭐ 핵심 와우 모먼트

```
사용자: "Redis 캐시에서도 지연이 발생하고 있어"

에이전트: [Recall 실행 — max_score: 0.12 🔴]
[Blindspot 자동 트리거]

"⚠️ 사각지대 감지:
 ┌─────────────────────────────────────────┐
 │  Redis 지식 밀도: 0.04  (기억 1건)      │
 │  Database 밀도:   0.87  (기억 23건)     │
 │  Kubernetes 밀도: 0.45  (기억 8건)      │
 │  Networking 밀도: 0.02  (기억 0건) 🔴   │
 └─────────────────────────────────────────┘
 Redis에 대한 경험이 거의 없습니다.
 제 추론의 신뢰도는 LOW입니다.
 → Redis 공식 문서 또는 팀 내 Redis 전문가 상담을 권합니다.

 일반 패턴 기반 추론 (참고용):
 DB 타임아웃과 동시 Redis 지연은 네트워크 계층 문제를 시사합니다."

사용자: [문제 해결 — 실제로 네트워크 스위치 장애]

에이전트: [Remember 실행]
"이 인시던트를 기억합니다:
 → entity: 'network-switch', attribute: 'failure-symptom',
   value: 'DB timeout + Redis latency 동시 발생'
 → Redis 밀도: 0.04 → 0.15 📈
 → Networking 밀도: 0.02 → 0.11 📈
 다음에 비슷한 증상이 나타나면 더 나은 진단을 할 수 있습니다."
```

### Act 3: Growth + Dashboard (2:00 - 3:00)

Kibana 대시보드 전환:

1. **Knowledge Heatmap**: 카테고리별 밀도를 색상으로 시각화
   - Database 🟢 | Kubernetes 🟡 | Redis 🟡(방금 업데이트) | Networking 🔴

2. **Memory Timeline**: 기억 생성/접근/통합/삭제의 시간 흐름
   - Episodic → Reflect → Semantic 승격 과정 시각화

3. **ILM Lifecycle View**: 기억의 수명주기
   - Hot(최근) → Warm(1주+) → Cold(1개월+) → 핵심만 Semantic으로 보존

4. **A/B 비교** (Memory OFF vs ON):
   ```
   Memory OFF: 도구 호출 12회, 재질문 5회, 해결 시간 15분
   Memory ON:  도구 호출 4회, 재질문 0회, 해결 시간 3분
   → 75% 시간 절약, 100% 재질문 감소
   ```

마무리:
> "Hippocampus — 기억하고, 잊고, 자기 한계를 아는 AI.
> Powered by Elasticsearch."

---

## 6. 14일 구현 계획

### Phase 1: Core Memory (Day 1-4)
| Day | 작업 | 산출물 |
|-----|------|--------|
| 1 | ES 인덱스 매핑 5개 + ILM 정책 | 인덱스 생성 스크립트 |
| 2 | Remember 도구 + SPO 추출 로직 | Agent Builder 도구 등록 |
| 3 | Recall 도구 (RRF hybrid + 가중 스코어) | 검색 동작 확인 |
| 4 | Contradict 도구 (ES\|QL 모순 탐지) | 모순 감지 데모 |

### Phase 2: Lifecycle (Day 5-7)
| Day | 작업 | 산출물 |
|-----|------|--------|
| 5 | Reflect Workflow (Scheduled + Alert) | 기억 통합 자동화 |
| 6 | Forget (ILM 연동 + 삭제 전 안전 확인) | 수명주기 동작 |
| 7 | E2E 테스트 (Remember→Recall→Contradict→Reflect→Forget) | 5도구 통합 테스트 |

### Phase 3: Blindspot (Day 8-10)
| Day | 작업 | 산출물 |
|-----|------|--------|
| 8 | knowledge-domains 인덱스 + Remember에 카테고리 태깅 | 밀도 추적 |
| 9 | Blindspot 도구 (Reactive + Proactive + Temporal) | 사각지대 탐지 |
| 10 | Recall↔Blindspot 자동 연동 + 통합 테스트 | 6도구 완성 |

### Phase 4: Demo (Day 11-14)
| Day | 작업 | 산출물 |
|-----|------|--------|
| 11 | Kibana 대시보드 (Heatmap + Timeline + ILM) | 시각화 |
| 12 | 데모 시나리오 시드 데이터 + 스크립트 | 데모 준비 |
| 13 | 3분 영상 촬영 + 편집 | 데모 영상 |
| 14 | README + 레포 정리 + Devpost 제출 | 최종 제출 |

---

## 7. 차별화: 기존 솔루션 비교

| 기능 | Mem0 | LangChain | Zep | **Hippocampus** |
|------|------|-----------|-----|-----------------|
| 기억 저장/검색 | ✅ | ✅ | ✅ | ✅ |
| 시맨틱 검색 | ✅ | ✅ | ✅ | ✅ RRF hybrid |
| 모순 탐지 | ❌ | ❌ | ❌ | ✅ ES\|QL SPO |
| 관리형 망각 | ❌ | ❌ | 부분 | ✅ ILM 5단계 |
| 기억 통합 | ❌ | ❌ | ❌ | ✅ Workflow |
| **사각지대 탐지** | ❌ | ❌ | ❌ | ✅ **유일** |
| 감사 추적 | 부분 | ❌ | ✅ | ✅ |
| 운영 준비 (lifecycle) | ❌ | ❌ | ❌ | ✅ ILM+Workflow |

**핵심 메시지**: "메모리를 저장하는 것은 누구나 한다. 모순을 잡고, 적절히 잊고, **자기 한계를 아는** 것은 Hippocampus만 한다."

---

## 8. 해커톤 심사 기준 매핑

| 심사 기준 (비중) | 점수 | 근거 |
|-----------------|------|------|
| 기술 실행력 30% | ★★★★★ | ES 6대 기능 전부 활용 (Search/ES\|QL/Workflow/MCP/ILM/conversation_id) |
| 영향력·혁신성 30% | ★★★★★ | "자기 무지를 아는 AI" = 새로운 패러다임. Blindspot은 기존 솔루션에 없음 |
| 데모 품질 30% | ★★★★☆ | 인시던트 코파일럿 시나리오 + "사각지대 감지" 와우 모먼트 + A/B 정량 비교 |
| 소셜 공유 10% | ★★★★☆ | "자기 한계를 아는 AI" — 개발자+비개발자 모두 흥미로운 카피 |

**이전 대비 개선**:
- 영향력·혁신성: ★★★★☆ → ★★★★★ (Blindspot 추가)
- 소셜 공유: ★★★☆☆ → ★★★★☆ ("자기 무지를 안다" 카피라이팅)
