## 3자 숙의 보고서: Hippocampus 방향성 검증 및 차별화

### 주제
Hippocampus + Blindspot 방향이 해커톤에서 가치가 있는지, 더 특별하게 만들 아이디어가 있는지

### 참가자
- Claude (Anthropic) — 오케스트레이터 겸 참가자
- Gemini (Google) — 설치됨
- Codex (OpenAI) — 설치됨

### 숙의 경과

**라운드 1**: "메모리 시스템" 프레이밍의 한계를 3자 모두 인정. Claude는 3가지 대안(감사/Contradict 킬링/도메인앱) 제시, Gemini는 "Self-Healing Knowledge Engine"으로 Contradict+Workflow 중심 재편 제안, Codex는 "Agent Trust/Audit Gate"로 Blindspot이 행동을 바꾸는 설계 제안. → "메모리"에서 "검증/감사"로 프레이밍 전환 합의.

**라운드 2**: Claude가 "Agent Guardrails" 프레이밍 + 4막 데모 구성 제시. Gemini는 전적 동의하며 Blindspot의 정교한 정의(밀도 기반)와 Contradict의 시계열성(Knowledge Drift) 보강 제안. Codex는 "완전 거부"를 "위험 기반 응답 제한"으로 수정, 경험 등급 계산 근거 가시화, "Trust Gate OFF vs ON" A/B 비교를 킬링 장면으로 제안. → 3자 완전 수렴.

### 수렴 결과
- **상태**: 완전 수렴
- **총 라운드**: 2

### 3자 합의 결론

**방향은 가치가 있다. 단, 프레이밍을 완전히 바꿔야 한다.**

| | Before | After |
|---|---|---|
| 프로젝트 정체성 | "AI 에이전트 메모리 시스템" | **"AI Agent Guardrails — 경험 기반 신뢰 게이트"** |
| 핵심 가치 | 기억 저장/검색 | **답변의 신뢰도를 경험 데이터로 검증하고 행동을 바꾸는 것** |
| 킬링 피처 | Remember/Recall | **Contradict(모순 탐지) + Blindspot(경험 공백 → 행동 트리거)** |
| 데모 와우 | "기억 검색" | **"Trust Gate OFF → 자신있게 틀림 / ON → 안전하게 제한"** |
| 차별화 | Mem0와 비슷 | **Mem0는 저장만, 우리는 검증+행동 변화** |

### 핵심 설계 결정 (3자 합의)

**1. Trust Gate 아키텍처**
- Recall + Contradict + Blindspot을 하나의 "Pre-flight Check"로 묶음
- 모든 답변 전에 자동 실행
- 결과에 따라 행동이 달라짐 (핵심 차별화)

**2. 경험 등급 (Experience Grade)**
- A: 근거 다수, 최근, 일관 → 자신있는 답변 + 근거 출처
- B: 근거 소수 또는 오래됨 → 답변 + "경험 제한적" 라벨
- C: 근거 희박 → 일반론 제공 + 미검증 라벨 + 추가 질문 생성
- D: 근거 없음 (Blindspot) → 일반론 최소 제공 + Workflow 트리거 (문서 검색/알림)
- CONFLICT: 모순 발견 → 모순 내용 제시 + 해소 경로(최신 승격/조건 분기) + 에스컬레이션

등급 계산은 ES|QL 집계로부터:
- 유사 사례 수 (COUNT)
- 최신성 (DATE_DIFF)
- 일관성 (COUNT_DISTINCT on value)
- 출처 신뢰도 (source_type 가중치)

**3. "답변 거부"가 아닌 "위험 기반 응답 제한"**
- 완전 거부 ✗ → "무능"으로 오해
- 제한 + 동시 행동 ✓ → 일반론 제공 + 미검증 라벨 + 후속 Workflow

**4. 데모 킬링 장면: Trust Gate OFF vs ON**
동일 질문을 두 번:
- Gate OFF: 에이전트가 자신있게 틀린 답 (과거 정보 기반)
- Gate ON: 에이전트가 모순을 감지하고 최신 경험 기반으로 교정
→ 10초 만에 가치 차이 즉시 이해

**5. 구현 우선순위 재편**

| 우선순위 | 구현 | 역할 |
|---------|------|------|
| P0 | Recall + Trust Gate (Contradict + Blindspot) | 핵심 제품 |
| P0 | 경험 등급 계산 (ES\|QL 기반) | 와우 근거 |
| P1 | Workflow 트리거 (알림/문서검색/추가질문) | 행동 변화 |
| P2 | Reflect (주간 요약 1건) + Forget (ILM 시각화) | 백그라운드 |
| P2 | Kibana 대시보드 (등급 히트맵/모순 로그) | 데모 비주얼 |
| P3 | Remember (자동 학습) | 성장 보여주기 |

### 보완된 관점

1. **Blindspot의 정교한 정의** (Gemini): 검색 결과 0건이 아니라, "주변 밀도는 높지만 직접 근거가 부족한 상태"로 정의해야 기술적 깊이가 드러남

2. **Contradict의 시계열성** (Gemini+Codex): 단순 "값이 다르다"가 아니라 Knowledge Drift(지식 표류) 관점. 모순 제시 후 해소 경로까지(최신 승격, 조건 분기)

3. **경험 등급의 계산 가시화** (Codex): ES|QL 집계 결과가 화면에 보여야 "임의 라벨"이 아닌 "데이터 기반 판단"임을 증명

4. **"조직 지식 드리프트 모니터링"** (Codex 대안): 에이전트를 벗어나 런북/포스트모템/결정기록의 모순을 상시 감시하는 제품으로도 확장 가능

### 최종 권고

**Hippocampus의 기술 아키텍처는 유지하되, 제품 정체성을 "Agent Guardrails"로 완전히 전환한다.**

핵심 메시지: **"LLM은 자신있게 틀릴 수 있다. 이 에이전트는 답변하기 전에 조직의 경험 데이터로 자기 검증한다. 근거가 없으면 행동을 바꾼다."**

이것은:
- "메모리 시스템"이 아니라 **"AI 신뢰성 도구"**
- Mem0/Zep과 **완전히 다른 카테고리**
- "기업이 AI를 실무에 투입하지 못하는 이유(신뢰성)"를 **정면 돌파**
- ES의 강점(ES|QL 분석, Workflow 트리거, ILM 수명주기)이 **필연적으로 사용됨**
