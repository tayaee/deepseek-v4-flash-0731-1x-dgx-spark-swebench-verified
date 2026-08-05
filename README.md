# DeepSeek-V4-Flash-0731 on Single DGX Spark

SWE-bench Verified (500) 베이스라인 측정용 레포. 엔진은 DGX Spark에서 `ds4-serve`로 띄우고, 에이전트/평가 컨테이너는 WSL2의 docker에서 돌린다.

## 1. 엔진 설치 / 기동 (DGX Spark)

```bash
curl -sSL https://raw.githubusercontent.com/entrpi/ds4-on-spark/main/install.sh | bash
./ds4-q3-16-ctx192k-banks3-graph512.sh                        # 192k ctx, banks=3, graph 512MB, reasoning=low
```

설정 핵심: `DS4_CUDA_NO_HBM_CACHE=1`, `DS4_SESSION_LAZY_GRAPH=0`, `DS4_BATCH_FIT_HEADROOM_MB=2048`, `DS4_SESSION_GRAPH_HEADROOM_MB=512`, `ds4-serve -c 196608 --tokens 8192 --no-dspark --reasoning-effort low`.

## 2. SWE-bench Verified 실행 (WSL2)

```bash
docker ps                                                     # 컨테이너 확인
./run-swebench-verified.sh                                    # Step1: LLM 추론 → Step2: 평가
./eval-swebench-verified.sh                                   # 평가만 단독 실행
./stop-swebench-verified.sh                                   # swebench 컨테이너 정리 (preds/traj 보존)
```

`OPENAI_API_BASE=http://spark1.local:8000/v1`로 mini-swe-agent가 spark의 `ds4-serve`를 호출한다. `preds.json`에 들어간 instance는 다음 실행 시 incremental로 스킵된다.

## 3. 결과 변환 (옵션)

```bash
./convert-preds-to-jsonl.sh <preds.json> <predictions.jsonl>   # preds.json → swebench harness용 jsonl
```

`eval-swebench-verified.sh`가 자동 감지하여 변환한다.
