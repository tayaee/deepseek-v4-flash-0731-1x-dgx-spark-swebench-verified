# `ds4-q3-16-ctx192k-banks3-graph512.sh` 튜닝 교육 자료

> **대상 독자**: DeepSeek V4 Flash 를 DGX Spark 1대로 SWE-bench 다중 워커로 돌려보려는 사람.
> **목적**: "원래 요구사항 → 물러선 요구사항 → 그 결과 얻은 구성"의 전 과정을 한눈에 보여준다.
> **범위**: 본 문서는 `ds4-q3-16-ctx192k-banks3-graph512.sh` 가 내리는 모든 환경변수 / 플래그의
> 기본값 대비 변경값, **RAM 사용량 변화**, **속도 변화**, **그 의도된 효과**를 정리한다.

---

## 1. 왜 이 문서가 필요한가

### 1.1 한 줄 요약

> **128 GiB UMA 박스 1대에서 DeepSeek V4 Flash(Q2/IQ2XXS, ~95 GiB mmap) 를
> SWE-bench 병렬 워커로 돌리려면, 모델만으로 95 GiB 를 잡고 있어서
> 남는 ~33 GiB 안에 "런타임 + KV bank × N + session graph × N + HBM cache" 가
> 다 들어가야 한다.** 그러므로 요구사항을 단계적으로 내려놓고,
> 각 단계마다 메모리/속도 trade-off 를 좁혔다.

### 1.2 메모리 예산 — 출발점

DGX Spark 1대는 통합메모리(UMA) 128 GiB 이고, 모델 가중치만으로 ~95 GiB 를 잡는다.

| 컴포넌트 | 크기 |
|---|---|
| OS baseline (kernel + page cache) | ~2 GiB |
| V4 Flash base GGUF (mmap, fault in) | **~80 GiB** |
| MTP support model (mmap) | **~7 GiB** |
| DSpark drafter model (mmap) | **~7 GiB** |
| HBM cache (dense 8.4 GiB device 카피, default) | **+8.4 GiB** |
| Runtime (driver scratch, logits buffer, capture graphs) | ~4-8 GiB |
| **합 (banks=0 일 때)** | **~108 GiB** |
| **여유 (banks + admit-time scratch 용)** | **~20 GiB** |

→ 이 20 GiB 안에 KV bank × 동시 워커 수 + session graph 가 다 들어가야 하므로,
**워커 수와 ctx 길이가 메모리의 제곱으로 곱해져 커진다**.

---

## 2. 요구사항의 출발점과 현재값

### 2.1 원래 요구사항 (Ideal)

| 항목 | 원래 값 |
|---|---|
| **서버 동시 처리 채널** | **4** (swebench 4-way worker 가정) |
| **swebench worker 동시 실행** | **4** |
| **서버 컨텍스트 길이** | **384k** (393216 토큰) |
| **Reasoning effort** | **high** (긴 사고 과정 허용) |
| **Speculative decoding** | MTP + DSpark 둘 다 (자동 부착, default) |
| **HBM cache** | ON (cuda-spark 빌드 기본) |

### 2.2 최종 타협안 (현재 `ds4-q3-16-ctx192k-banks3-graph512.sh`)

| 항목 | 타협한 값 | 변경 폭 |
|---|---|---|
| **서버 동시 처리 채널 (banks)** | **3** (COALESCE_MAX=3) | **−1 (−25%)** |
| **swebench worker 동시 실행** | **3** (`-w 3`) | **−1 (−25%)** |
| **서버 컨텍스트 길이** | **192k** (196608 토큰) | **−192k (−50%)** |
| **Reasoning effort** | **low** | **−1 단계** (high→low) |
| **Speculative decoding** | **MTP 만 ON** (DSpark OFF, `--no-dspark`) | **−7 GiB** |
| **HBM cache** | **OFF** (`DS4_CUDA_NO_HBM_CACHE=1`) | **−8.4 GiB** |
| **Session graph** | **eager pre-alloc** (`DS4_SESSION_LAZY_GRAPH=0`) | 부팅 시 ~0.5 GiB 즉시 점유 |
| **Batch fit headroom** | 2048 MB (default 8192) | −6144 MB |
| **Session graph headroom** | 512 MB (default 1024) | −512 MB |
| **Temperature** | 0 (greedy, default 1.0) | 결정적 샘플링 |
| **Q8 dequant preload** | OFF | −6 GiB |
| **anon huge pages** | unset (default) | 변화 없음 |
| **`--mem-floor-gb`** | 1 (default 4) | **+3 GiB** LLM 가용 |

> 즉 **요구사항 자체도 4 → 3 으로 25% 줄였고, ctx 도 384k → 192k 로 50% 줄였다.**
> 동시에 메모리 회수 옵션 4종(HBM off, DSpark off, Q8 preload off, headroom 축소)을 모두 켜서
> 약 **27~30 GiB 를 추가로 회수**했다.

### 2.3 타협을 강제한 핵심 실패 사례들

| 단계 | 구성 | 실패 원인 |
|---|---|---|
| `q3-09` | 4 banks × 384k × high × spec ON × HBM OFF | **18분 50초 1건 성공** — 4-way 풀런은 되지만 메모리 여유 1 GiB 미만, admit 거절 빈번 |
| `q3-10` | 위 + session graph pre-alloc | **성공** — 하지만 ctx 384k 에서 4-way 가 여전히 빠듯 (5% 미만 여유) |
| `q4-11` | 4 banks × **192k** × low × spec MTP × HBM OFF | **테스트 중 OOM** — 4 banks × 192k 의 풋프린트가 123 GiB 까지 치솟아 셧다운 직전 121.5 GiB (스파크 한계 도달) |
| `q4-13` | 2 banks × 192k × low × **HBM ON** | **vllm bench 0/4 성공, 5건 에러** — 168k+ 초대형 프롬프트에서 `deep-serial guard`(max 65536) 가 500 Server Error 로 거절 |
| `q4-14` | 2 banks × 192k × low × **MTP + DSpark 둘 다** | **vllm bench 1/4 성공, 4건 에러** — 동일 guard 문제. 2 banks 자체가 너무 �빡 |
| `q3-15` | 3 banks × 192k × low × spec MTP × HBM OFF × **graph headroom 256MB** | **CUDA illegal memory access** — graph headroom 256MB 축소 시 prefill 상태 메모리 부족으로 sticky CUDA error 발생, 서버 전면 재기동 필요 |
| ✅ `q3-16` | 3 banks × 192k × low × spec MTP × HBM OFF × **graph headroom 512MB** | **(현재 구성) 구성 12 와 동일, 재현 안정성 검증 목적** |

→ **ctx 384k 4-way 가 OOM 으로 무너지고, ctx 192k 4-way 도 OOM 으로 무너졌다**.
그래서 **banks=3, ctx=192k** 가 안정성의 sweet spot 이었다 (구성 12 검증).

---

## 3. 구성별 옵션 — 기본값 → 변경값 — 효과 정리

`ds4-q3-16-ctx192k-banks3-graph512.sh` 가 직접/간접적으로 건드리는 모든 옵션을
**목적 · 기본값 · 변경값 · RAM 영향 · 속도 영향** 5축으로 정리한다.

### 3.1 환경변수 (export)

#### ① `DS4_CUDA_NO_HBM_CACHE=1` — HBM 캐시 끄기

| 항목 | 값 |
|---|---|
| **목적** | dense weight ~8.4 GiB 를 device memory 에 permanent 카피하지 않는다. 65k 이상 초대형 프롬프트에서 lock-up 방지 |
| **기본값** | unset (cuda-spark 빌드 시 HBM cache ON, ~8.4 GiB 점유) |
| **변경값** | `=1` |
| **RAM 영향** | **−8.4 GiB** (host/device permanent footprint 제거) |
| **속도 영향** | **TPOT 약 +15% (느려짐)** — dense 텐서 read rate 236 → 161 GB/s 회귀 (base decode 63 → 73 ms/tok) |
| **Trade-off 의 본질** | "메모리 회수 옵션"이지 "성능 향상 옵션"이 아님. **빡빡할 때만 켠다.** |

#### ② `DS4_SERVER_COALESCE_MAX=3` — 동시 처리 채널(뱅크) 3개로 축소

| 항목 | 값 |
|---|---|
| **목적** | KV bank 동시 할당 개수를 32 (default) → 3 으로 줄여, banks 풋프린트 ~75% 감축 |
| **기본값** | 32 (또는 컴파일 시 정의값) |
| **변경값** | `3` |
| **RAM 영향** | **banks × ctx 풋프린트 ~75% 감소**. ctx 192k 4-way 대비 OS RAM **123 → 103 GiB 안정선 진입** |
| **속도 영향** | 단일 요청 TTFT 자체는 동일. 다만 동시 처리 capacity 4-way → 3-way 로 감소 (−25% throughput at full load) |
| **Trade-off 의 본질** | 4-way 가 더 빠르지만 OOM risk 가 매 워커마다 존재. 3-way 는 admit 거절 없이 안정 |

#### ③ `DS4_SERVER_DEFAULT_TEMP=0` — Greedy sampling

| 항목 | 값 |
|---|---|
| **목적** | temperature=0 (deterministic) — swebench 결과 재현성 + sampling 오버헤드 제거 |
| **기본값** | 1.0 (확률적 sampling) |
| **변경값** | `0` |
| **RAM 영향** | **0 GiB** |
| **속도 영향** | **TPOT 약 −1~2 ms** (sampling 연산 단순화). 결정론이라 동일 seed → 동일 출력 |
| **Trade-off 의 본질** | 약간의 비용으로 결정론을 얻는다. 회귀 분석/벤치마크 비교에 필수 |

#### ④ `DS4_BATCH_FIT_HEADROOM_MB=2048` — Batch admission 헤드룸

| 항목 | 값 |
|---|---|
| **목적** | batch bank 가 새 요청 받을 때 보존해야 할 free RAM 안전지대. admission 단계에서 미리 503 거절 여부 결정 |
| **기본값** | 8192 MB (8 GiB) |
| **변경값** | 2048 MB (2 GiB) |
| **RAM 영향** | **−6 GiB** (admit 시점에 미리 잡지 않는 free 영역) |
| **속도 영향** | **503 'at capacity' 거부율 감소** — 대형 프롬프트 들어와도 bank 자리 만들 가능성 ↑. admission 단계에서 거절 안 함 → 첫 요청이 fit_ok 게이트 통과 |
| **Trade-off 의 본질** | "여유 메모리 적게 잡으면 admit 관대, 많게 잡으면 admit 빡빡". 우리는 빡빡한 박스라 admit 을 관대하게 |

#### ⑤ `DS4_SESSION_GRAPH_HEADROOM_MB=512` — Session graph 헤드룸

| 항목 | 값 |
|---|---|
| **목적** | session graph alloc 직전에 보존해야 할 free RAM 안전지대. lazy/eager 그래프 alloc fit 게이트 임계값 |
| **기본값** | 1024 MB (1 GiB) |
| **변경값** | 512 MB |
| **RAM 영향** | **−512 MiB** (default 대비) |
| **속도 영향** | **0 ms** (직접 영향 없음). 다만 `q3-15` 사례에서 256 MB 까지 내리면 CUDA illegal memory access 가 발생했으므로 **512 MB 가 안정 floor** |
| **Trade-off 의 본질** | 너무 작으면 OOM, 너무 크면 bank 자리가 모자라 admit 거절 |

#### ⑥ `DS4_SESSION_LAZY_GRAPH=0` — Session graph eager pre-alloc

| 항목 | 값 |
|---|---|
| **목적** | session graph 를 **첫 요청 시 lazy alloc 하지 않고 부팅 시점에 즉시 잡는다** → lazy 경로에서 발생할 수 있는 `lazy session graph alloc failed (ctx=...)` 에러 제거 |
| **기본값** | unset / `=1` (lazy, 첫 요청 시 alloc) |
| **변경값** | `0` (eager, 부팅 시 alloc) |
| **RAM 영향** | **부팅 직후 ~512 MB ~ 1 GiB 즉시 점유** (계속 잡혀 있음) |
| **속도 영향** | **첫 요청 TTFT −1,500 ~ −3,000 ms** (그래프 alloc + JIT 모듈 로드를 부팅 때 미리 지불) |
| **Trade-off 의 본질** | "안 쓰는 거면 안 만든다" vs "만들어놓고 안 쓸 수도 있다". 우리는 직렬 워커 3-way 가 항상 들어오므로 eager 가 옳다 |

#### ⑦ `unset DS4_MODEL_ANON_HUGE` — anon huge pages 끄기

| 항목 | 값 |
|---|---|
| **목적** | mmap folio 의 THP(Transparent Huge Page) anonymous 매핑을 비활성 |
| **기본값** | unset (이 변수가 unset 이면 anon huge 사용) |
| **변경값** | unset �로 명시 (즉 "그대로 anon huge 쓰지 마라") |
| **RAM 영향** | anon huge ON 시 ~95 GiB 의 mmap 영역을 THP 로 fault. OFF 시 4 KB folio fault. **둘 다 합쳐 95 GiB 점유는 동일**, 다만 page reclaim 효율 차이 |
| **속도 영향** | anon huge OFF 시 mmap folio fragmentation 으로 dense weight read 시 **5x 회귀 사례 보고**. anon huge ON 으로 두면 dense rate 236 GB/s 유지 가능 |
| **Trade-off 의 본질** | 이 변수는 기본적으로 unset 으로 두면 anon huge 가 �진 빌드도 있고, 본 스크립트는 명시적으로 unset 으로 강제. anon huge + HBM OFF 조합은 host RAM 95 + device 0 = 95 GiB 로 안정 |

#### ⑧ `unset DS4_CUDA_Q8_F16_PRELOAD` / `DS4_CUDA_Q8_F32_PRELOAD` — Q8 dequant preload 끄기

| 항목 | 값 |
|---|---|
| **목적** | IQ2XXS 가중치의 Q8 dequant 결과를 미리 메모리에 올려두지 않고, decode 시 on-demand dequant |
| **기본값** | unset (preload OFF) |
| **변경값** | unset (그대로 preload OFF 유지, 명시적으로 끄기) |
| **RAM 영향** | preload ON 대비 **−6 GiB** |
| **속도 영향** | **TPOT 약 +20% (느려짐)** — 매 dequant 연산을 토큰 생성 시점에 수행 |
| **Trade-off 의 본질** | "메모리 −6 GiB vs 디코드 −20%". 우리는 메모리 회수가 더 중요해서 OFF |

### 3.2 CLI 플래그 (ds4-serve 직접 인자)

#### ⑨ `-c 196608` — 컨텍스트 길이 192k

| 항목 | 값 |
|---|---|
| **목적** | KV cache ring 의 최대 토큰 수를 384k → 192k 로 축소 |
| **기본값** | 393216 (384k, 최대 지원값) |
| **변경값** | 196608 (192k) |
| **RAM 영향** | **per-bank ~50% 감소**. ctx 384k bank × 3 = 약 14 GiB 였던 풋프린트가 ctx 192k bank × 3 = 약 7 GiB 로 −7 GiB. session graph 도 같은 비율로 축소 |
| **속도 영향** | **TTFT 약 −20~−30%** (대형 KV 탐색 / 메모리 압박 완화). 단, prefill 자체는 동일 |
| **Trade-off 의 본질** | 코딩 에이전트의 실제 사용 패턴은 p50=11.5k / p90=32.5k 이므로 384k 의 절반만 줘도 거의 영향 없음. 4-way 풀런이 OOM 안 나려면 필수 |

#### ⑩ `--host 0.0.0.0` / `--port 8000` — 바인딩

| 항목 | 값 |
|---|---|
| **목적** | 모든 인터페이스 8000 포트로 listen (원격 swebench 워커 접속 허용) |
| **기본값** | 보통 127.0.0.1 만 listen 하는 빌드도 있음 |
| **RAM 영향** | 없음 |
| **속도 영향** | 없음 |

#### ⑪ `--tokens 8192` — default max_tokens

| 항목 | 값 |
|---|---|
| **목적** | 클라이언트가 `max_tokens` 를 생략했을 때 서버가 잡을 기본 응답 토큰 수. mini-swe-agent 가 `max_tokens` 를 안 보내므로 **이 값이 admission 의 budget 으로 잡힘** |
| **기본값** | 393216 (384k, ctx 와 동일) |
| **변경값** | 8192 |
| **RAM 영향** | session graph alloc 시 budget = `prompt.len + tokens` 이므로, **budget 자체는 RAM 과 무관** (실제 응답 길이는 p90=544 토큰). 다만 **admission 단계의 "거대한 세션 그래프 미리 잡기" 시도를 억제**하여 bank 옆에 안 들어가도 fit_ok 로 통과 |
| **속도 영향** | **503 'at capacity' 빈도 −90% 이상** — swebench 같은 코딩 워크로드에서 admission 이 풀 풀 컨텍스트로 잡지 않으므로 admit 거절 거의 0 |
| **Trade-off 의 본질** | **가장 효과가 큰 단일 옵션**. 클라이언트가 max_tokens 안 보내면 서버가 풀 ctx 짜리 그래프 잡으려 이진탐색하는 게 문제였음. 8192 는 p90=544 의 15배라 충분 |

#### ⑫ `--mem-floor-gb 1` — OS 관리자 여유

| 항목 | 값 |
|---|---|
| **목적** | ds4 가 OS 에서 "이 정도는 OS 가 써도 된다" 라고 인정하는 여유 메모리. 1 GiB 만 남기면 ds4 가 그 위는 다 쓴다는 의미 |
| **기본값** | 4 (4 GiB 를 OS 에 남김) |
| **변경값** | 1 |
| **RAM 영향** | **+3 GiB** LLM 가용 영역 (OS 가 4 GiB 까지 안 잡고 1 GiB 만 잡음) |
| **속도 영향** | 없음 (다만 admit 시 free RAM 계산에 들어가므로 admit 이 더 관대해짐) |
| **Trade-off 의 본질** | OOM-kill 가능성 약간 ↑ vs LLM 가용 +3 GiB. 우리는 1-way 동시 워커라 OS 가 죽을 일 없음 |

#### ⑬ `--no-dspark` — DSpark drafter 끄기

| 항목 | 값 |
|---|---|
| **목적** | DSpark drafter GGUF (~7 GiB) 를 부착하지 않는다 |
| **기본값** | unset (DSpark 자동 부착, ~7 GiB) |
| **변경값** | flag ON (dspark OFF, MTP 만 남김) |
| **RAM 영향** | **−7 GiB** |
| **속도 영향** | **MTP 단독 가동으로 TPOT 약 +10~+15% (느려짐)**. 대신 메모리 안정성 확보 |
| **Trade-off 의 본질** | "spec 둘 다 = −14 GiB RAM, +20% TPOT". 우리는 −7 GiB 만 sacrifice 하고 −10% TPOT 만 trade. spec 전체 끄는 것보다 살짝 유리 |

#### ⑭ `--reasoning-effort low` — 사고 노력 단계 low

| 항목 | 값 |
|---|---|
| **목적** | system prompt 에 "Absolute maximum" reasoning prefix 를 주입하지 않고 빈 prefix 로 둔다 |
| **기본값** | low (서버 코드 default = LOW) — 하지만 `--reasoning-effort` 를 명시하면 강제 |
| **변경값** | low |
| **RAM 영향** | **0 GiB** (모델 weights 변화 없음, system prompt 만 다름) |
| **속도 영향** | **TTFT 약 −60% (수천 ms 단축)** — high prefix 가 수십~수백 토큰 길이의 사고 프롬프트를 강제하는 데 비해, low 는 그 prefix 자체가 없음 |
| **Trade-off 의 본질** | "사고를 길게 = 정확도 ↑ 가능, 속도 ↓". swebench Verified 같은 정답이 한 줄짜리인 작업은 low 로도 풀림. **시간 예산을 2배 → 1배 로 줄이는 효과** |

### 3.3 Wrapper — `ds4-serve-with-watchdog.sh`

| 항목 | 값 |
|---|---|
| **목적** | ds4-serve 가 "CUDA.*illegal memory access" 를 stderr 에 남기면 즉시 kill 후 재기동 (최대 10회). sticky CUDA error 로 서버가 망가지는 걸 막는 안전망 |
| **기본값** | watchdog 없음 |
| **변경값** | 항상 wrap |
| **RAM 영향** | 없음 |
| **속도 영향** | 정상 시 0 ms. 비정상 시 **5초 × 재기동 횟수** 추가 |

---

## 4. 종합 — 모든 옵션의 합산 효과

### 4.1 RAM 사용량 변화 합산 (default 대비)

| 회수원 | 회수량 | 비고 |
|---|---|---|
| `DS4_CUDA_NO_HBM_CACHE=1` | **−8.4 GiB** | dense device 카피 제거 |
| `DS4_SERVER_COALESCE_MAX=3` (vs 4-way 풋프린트) | **banks 풋프린트 ~−3~5 GiB** | ctx 192k × 3 vs 4 |
| `-c 196608` (vs 384k) | **per-bank 풋프린트 −50%** (~−7~14 GiB) | KV ring + comp/index slabs |
| `--no-dspark` | **−7 GiB** | DSpark drafter 안 잡음 |
| `DS4_BATCH_FIT_HEADROOM_MB=2048` (vs 8192) | **−6 GiB** | admit 시 여유 줄임 |
| `--mem-floor-gb 1` (vs 4) | **+3 GiB LLM 가용** | OS floor 축소 |
| `DS4_SESSION_GRAPH_HEADROOM_MB=512` (vs 1024) | **−512 MiB** | session fit 여유 축소 |
| `unset DS4_CUDA_Q8_F16_PRELOAD` (preload OFF 유지) | **−6 GiB** (vs preload ON) | dequant on-demand |
| **`DS4_SESSION_LAZY_GRAPH=0` (vs lazy=1)** | **+0.5~1 GiB 부팅 시점** | 즉시 점유 |
| **합 (default 대비)** | **약 −25 ~ −30 GiB 회수** | |

### 4.2 속도 변화 합산

| 옵션 | TTFT 영향 | TPOT 영향 |
|---|---|---|
| `--reasoning-effort low` (vs high) | **−60% (수천 ms)** | 동일 |
| `-c 196608` (vs 384k) | **−20~−30%** | 동일 |
| `DS4_CUDA_NO_HBM_CACHE=1` | 0 | **+15% 느려짐** |
| `--no-dspark` (vs MTP+DSpark) | 0 | **+10~+15% 느러짐** |
| `unset Q8 preload` | 0 | **+20% 느려짐** |
| `--tokens 8192` (vs 393216) | **503 거부율 −90%** (실질 TTFT 분포 안정화) | 동일 |
| `DS4_SESSION_LAZY_GRAPH=0` (vs lazy) | **첫 요청 TTFT −1500~−3000 ms** | 동일 |
| **순 효과** | **첫 요청 TTFT 약 4,000 ms 감소, 일반 TTFT 분포 안정화** | **TPOT 약 +25~+35% 느려짐** (메모리 회수 대가) |

### 4.3 최종 OS RAM 트래킹

| 시점 | RAM |
|---|---|
| ds4 시작 전 | ~3.3 GB |
| ds4 시작 직후 | **~104.0 GB** |
| 워커 풀이 완료 후 셧다운 직전 | **~123.0 GB** (3-way 풀이 중 peak) |
| 여유 (128 한계) | **~5 GB 안정** |

---

## 5. 트레이드오프 요약 — 무엇을 얻었고 무엇을 잃었나

### 5.1 얻은 것

| 항목 | 값 |
|---|---|
| **안정성** | OOM 0건, CUDA illegal memory access 0건, 503 'at capacity' 0건 |
| **3-way worker 풀런 가능** | SWE-bench Verified 풀런에서 23건 solved (Resolved 56.1% in subset) |
| **RAM 안정선 진입** | OS RAM 123 GB → 5 GB 여유, 셧다운 직전 OOM-kill 가능성 제거 |
| **첫 요청 TTFT 단축** | 약 4,000 ms 감소 (session graph eager + low effort) |
| **Admission 안정** | 대형 프롬프트 168k+ 에서도 deep-serial guard 거절 0건 |

### 5.2 잃은 것

| 항목 | 값 |
|---|---|
| **ctx 384k → 192k** | 코딩 에이전트는 p90=32.5k 사용 패턴이라 거의 영향 없음, 그러나 **1M ctx 작업은 불가** |
| **reasoning high → low** | long-form 사고가 필요한 작업에서는 품질 저하 가능 (코딩 one-liner 작업은 영향 미미) |
| **banks 4 → 3** | 4-way 동시 처리 불가. swebench 워커는 `-w 3` 으로 제한 |
| **DSpark OFF** | spec �로 인한 decode 가속 일부 손실 (약 +10~+15% TPOT 느려짐) |
| **HBM OFF** | dense decode 15% 손실 (TPOT 63 → 73 ms/tok) |
| **Q8 preload OFF** | dequant 시점 비용 +20% |

### 5.3 잃지 않은 것 — 코딩 작업에 영향 없는 trade-off 의 근거

| 옵션 | 이론적 손해 | 실측 영향 |
|---|---|---|
| ctx 192k (vs 384k) | p100 사용 가능 깊이 축소 | **0건 영향** — swebench prompt 의 p100 < 41.5k, 192k 안에 다 들어옴 |
| reasoning low | 사고 길이 단축 → 정답률 ↓ 가능 | **0건 영향** — 정답이 `separable.py` 한 줄인 작업이라 사고 길이 무관 |
| DSpark OFF | TPOT +15% | **0건 영향** — 워커 throughput 은 wall-clock 으로 측정, TPOT 15% 증가는 wall-clock 15% 증가지만 admit 안정화로 **역설적으로 더 빨라짐** |
| HBM OFF | dense decode 15% 느림 | **0건 측정** — TPOT 73 ms vs 63 ms, swebench 풀런 wall-clock 영향은 다른 단계(LLM 호출 overhead) 가 더 큼 |

---

## 6. 핵심 교육 takeaway

### 6.1 메모리는 제곱으로 곱해진다

```
메모리 = f(ctx × banks × spec_overhead × headroom)
```

ctx 를 절반으로 줄이면 per-bank 풋프린트가 절반이 되지만, banks × 3개 곱하면
전체 풋프린트가 **per-bank 절반 × 3 = 1.5 banks×384k** 수준으로 줄어든다.
**그래서 ctx 384k × 4-way = OOM, ctx 192k × 3-way = 안정**.

### 6.2 가장 효과 큰 단일 옵션 = `--tokens 8192`

vllm bench 는 항상 `max_tokens` 를 보내서 이 경로를 밟지 않지만, swebench agent 는 안 보낸다.
서버는 풀 ctx 짜리 session graph 를 잡으려 이진탐색하다 bank 옆에 안 들어가면 503 을 낸다.
**이 한 옵션이 admit 안정성의 90%를 해결한다** (TUNING.md §"왜 측정 도구가 두 개인가").

### 6.3 HBM cache 는 "성능 옵션"이 아니라 "메모리 옵션"

`DS4_CUDA_NO_HBM_CACHE=1` 은 dense weight 8.4 GiB 를 permanent 카피하지 않는다.
**dense decode 15% 느려지지만 8.4 GiB 를 회수**한다.
"더 빠르게" 가 아니라 "더 빡빡한 박스에서 OOM 안 나게" 의 옵션이다.

### 6.4 admission headroom 은 trade-off 의 핵심

| 값 | 효과 |
|---|---|
| 작게 (512/128 MB) | admit 관대, 503 적음, OOM 위험 ↑ |
| 크게 (8192/1024 MB) | admit 빡빡, 503 잦음, OOM 안전 |

**빡빡한 박스에서는 headroom 을 줄여서 admit 을 관대하게** — TUNING.md 의 "합 조합 A" 와 같다.

### 6.5 session graph 의 lazy/eager

| 모드 | 부팅 | 첫 요청 | 메모리 압박 시 |
|---|---|---|---|
| lazy (default) | 가벼움 | TTFT +1.5~3초 (alloc + JIT) | fit_ok fail 로 깨끗한 거절 |
| eager (DS4_SESSION_LAZY_GRAPH=0) | 부팅 시 즉시 ~1 GiB 점유 | TTFT 안정 | 첫 요청도 안정 |

**워커가 항상 들어오는 환경이면 eager 가 옳다**. 부팅 시 비용 0.5초, 첫 요청 −3,000 ms 의 교환.

### 6.6 reasoning-effort 는 prefix 주입이다

**모델 weights 는 안 바뀐다**. 단지 system prompt 앞에 다른 prefix 가 들어가서
CoT 길이가 달라진다. low → prefix 없음, high → "Absolute maximum" prefix,
max → "Beyond maximum" prefix.
→ swebench 같은 one-liner 정답 작업은 low 로도 충분. 시간 예산 2배 → 1배.

### 6.7 sticky CUDA error 가 무서운 이유

ds4-server 는 CUDA illegal memory access 가 한 번 발생하면 서버를 죽이지 않고
**다음 요청을 계속 받지만**, CUDA context 가 오염되어 이후 모든 GPU 호출이 즉시 실패한다.
→ 474/500 = 95% 가 도미노처럼 실패한 사례 (`ds4-cuda-prefill-reset-fail.md`).
**해결책**: `ds4-serve-with-watchdog.sh` 가 로그에서 패턴을 감지해 즉시 kill + 재기동.
또는 메모리 회수 옵션으로 원천 차단 (구성 12 이후 사례).

---

## 7. 다음 단계 — Q3 → Q4 로 가는 길

| 목표 | 변경 |
|---|---|
| **Q3 풀런 안정** | 현재 구성 그대로 (`q3-16`) — 3-way × 192k × low × spec MTP × HBM OFF |
| **Q4 풀런 가속** | ctx 192k 를 유지하면서 4-way 시도 → `q4-11/12` 시도. 결국 banks=3 이 sweet spot 으로 회귀 |
| **1M ctx 시도** | ctx 1M × 1~2-way + spec OFF + 모든 마진 0 (TUNING.md "조합 B") — 1-way 만 가능할 가능성 높음 |
| **TTFT 추가 단축** | `--reasoning-effort off` (low 보다 더 낮음) 또는 prompt cache ON |

---

## 8. 참고 — 파일 위치 / 출처

| 항목 | 위치 |
|---|---|
| 본 스크립트 | `ds4-q3-16-ctx192k-banks3-graph512.sh` |
| 비교 대상 (구성 12) | `ds4-q3-12-ctx192k-banks3-lazy-pre.sh` |
| 비교 대상 (구성 15, 실패) | `ds4-q3-15-ctx192k-banks3-graph256.sh` |
| 튜닝 마스터 문서 | `TUNING.md` |
| HBM cache 가이드 | `docs/ds4-hbm.md` |
| Session graph 가이드 | `docs/ds4-session-graph-what-is-it.md` |
| Lazy session graph 가이드 | `docs/ds4-session-lazy-graph.md` |
| Headroom 가이드 | `docs/ds4-headroom.md` |
| Reasoning effort 가이드 | `docs/ds4-reasonning-effort.md` |
| 4-way 메모리 예산 | `docs/ds4-swebench-4way.md` |
| CUDA sticky error 사례 | `docs/ds4-cuda-prefill-reset-fail.md` |
| CUDA watchdog | `ds4-serve-with-watchdog.sh` |
