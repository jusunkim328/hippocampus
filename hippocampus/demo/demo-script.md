# Hippocampus Demo Script — Trust Gate OFF vs ON

> **소요 시간**: 약 3분
> **목적**: Trust Gate가 LLM의 "자신있는 오답"을 어떻게 방지하는지 시연

---

## 준비 사항

- [ ] Elasticsearch 클러스터 실행 확인
- [ ] 시드 데이터 투입 완료 (`setup/` 스크립트 실행)
- [ ] Kibana 대시보드 로드 완료 (`dashboard/hippocampus-dashboard.ndjson` 임포트)
- [ ] 에이전트 등록 완료 (Agent Builder에서 hippocampus-agent 확인)

---

## Act 1: Trust Gate OFF (0:00 - 0:40)

### 시나리오

일반 LLM에게 질문:

> "Payment 서비스에서 DB 커넥션 타임아웃이 반복 발생하고 있습니다. 어떻게 해결해야 하나요?"

### 예상 응답 (일반 LLM)

```
DB 커넥션 타임아웃 문제를 해결하려면:

1. 커넥션 풀 사이즈를 늘리세요 (50 추천)
2. 타임아웃 값을 30초로 조정하세요
3. HikariCP 설정을 최적화하세요
4. 데이터베이스 인덱스를 점검하세요
```

**문제점**:
- 3개월 전 정보 기반의 답변
- 최신 경험(커넥션 풀 50 -> 100 증설로 해결)을 전혀 모름
- **자신있게 틀린 답변**을 제공

### 화면 구성

- 일반 ChatGPT/Claude 인터페이스에서 질문하는 화면
- "자신있는" 답변 부분을 강조 표시

---

## Act 2: Trust Gate ON — The Known (0:40 - 1:30)

### 시나리오

동일한 질문을 Hippocampus 에이전트에게 전달

> "Payment 서비스에서 DB 커넥션 타임아웃이 반복 발생하고 있습니다. 어떻게 해결해야 하나요?"

### Trust Gate 프로세스 (실시간 표시)

| 단계 | 동작 | 결과 |
|------|------|------|
| **Step 1: Recall** | episodic-memories에서 검색 | 15건+ 매칭 (Grade A 수준) |
| **Step 2: Grade 판정** | 경험 밀도 평가 | "Grade A: 충분한 근거" |
| **Step 3: Contradict Check** | entity=`payment-service`, attribute=`db-connection-pool-size` | **CONFLICT 감지!** |

**CONFLICT 상세**:
- **이전 경험**: "50이 최적" (confidence 0.7, 3개월 전)
- **최신 경험**: "50 -> 100 증설로 해결" (confidence 0.9, 오늘)

### 에이전트 응답 예시

```
📊 Experience Grade: A (충분) — 근거 15건, 최근 30일 이내

⚡ CONFLICT 감지: db-connection-pool-size
  - [이전 경험] 2025-11-15: "50이 최적" (confidence: 0.7)
  - [최신 경험] 2026-02-12: "50→100 증설로 해결" (confidence: 0.9)
  → 최신 경험을 우선합니다.

## 권장 조치
1. 커넥션 풀 사이즈를 100으로 증설 (최신 경험 기반)
2. 타임아웃을 5초→10초로 조정 (conv-db-005 근거)
3. HikariCP 메트릭을 Prometheus로 모니터링 설정

📌 출처: conv-db-018, conv-db-005, conv-db-012
```

### 화면 구성

- Trust Gate 프로세스가 **단계별로 실행**되는 모습
- CONFLICT 감지 부분 **하이라이트**
- 교정된 답변 **강조** (이전 답변과 비교)

---

## Act 3: Trust Gate ON — The Unknown (1:30 - 2:20)

### 시나리오

> "Redis 캐시에서도 지연이 발생하고 있습니다. Redis 장애 대응 방법을 알려주세요."

### Trust Gate 프로세스

| 단계 | 동작 | 결과 |
|------|------|------|
| **Step 1: Recall** | episodic-memories에서 검색 | **2건만 매칭** (매우 부족) |
| **Step 2: Grade 판정** | 경험 밀도 평가 | **Grade D 판정** |
| **Step 3: Blindspot 자동 트리거** | `hippocampus-blindspot-targeted(domain="redis")` | density=1.5, status="SPARSE" |

### 에이전트 응답 예시

```
📊 Experience Grade: D (사각지대)

🔴 사각지대 감지: redis 도메인
  - 경험 밀도: 1.5 (SPARSE)
  - 보유 기억: 3건 (충분한 근거 부족)

## 일반론 (LOW confidence — 조직 경험 미검증)
1. Redis 메모리 사용량 확인 (maxmemory 설정 검토)
2. 슬로우 로그 확인 (SLOWLOG GET)
3. 클라이언트 연결 수 확인

⚠️ 이 답변은 조직의 검증된 경험이 아닌 일반 지식에 기반합니다.
💡 권장: Redis 전문가 (@redis-team)에게 확인을 요청하세요.
```

### 화면 구성

- Blindspot **자동 트리거** 과정 표시
- 사각지대 라벨 **강조** (빨간색)
- 전문가 추천 표시 (`@redis-team`)

---

## Act 4: Growth + Dashboard (2:20 - 3:00)

### 시나리오

인시던트 해결 후 새로운 경험을 저장합니다.

### Remember 호출

```
hippocampus-remember:
  - entity: cache-server
  - attribute: latency-fix
  - value: "Redis maxmemory를 2GB→4GB로 증설하고 eviction policy를 allkeys-lru로 변경하여 해결"
  - confidence: 0.85
  - category: redis
```

### 결과

| 항목 | Before | After |
|------|--------|-------|
| Redis 도메인 밀도 | 1.5 | 2.35 |
| 상태 | SPARSE | SPARSE (개선 중) |

### Kibana 대시보드 전환

대시보드에서 4가지 변화를 확인합니다:

1. **Knowledge Density Heatmap**: Redis 영역 색상 변화 (빨강 -> 노랑 방향)
2. **Experience Grade Distribution**: Grade D 비율 감소
3. **Memory Timeline**: 새 기억 추가 표시
4. **Trust Gate Activity**: Recall -> Contradict -> Blindspot 호출 추이

### 클로징 메시지

> **"Trust Gate: LLM이 자신있게 틀리는 것을 방지합니다."**
> 근거가 있으면 자신있게, 없으면 솔직하게, 모순이 있으면 교정하여 답변합니다.

---

## 키 메시지

| # | 메시지 | 설명 |
|---|--------|------|
| 1 | **Before** | LLM은 모든 질문에 자신있게 답변 (틀려도 자신있게) |
| 2 | **After** | Trust Gate가 답변 전 경험 데이터로 검증 |
| 3 | **Growth** | 새 경험이 축적될수록 에이전트가 성장 |
| 4 | **Transparency** | 사각지대를 숨기지 않고 투명하게 공개 |

---

## 발표 팁

- Act 1과 Act 2를 **나란히 비교**하면 효과적
- CONFLICT 감지 순간에 **잠시 멈추고** 청중의 반응을 확인
- Act 3의 "솔직하게 모른다"는 부분을 **강조**
- Act 4의 대시보드는 **실시간 변화**를 보여주면 임팩트가 큼
