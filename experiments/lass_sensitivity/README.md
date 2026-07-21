# LASS Sensitivity Experiment: Besu & Nethermind @ 1GB Heap

**Date:** 2026-04-22 ~ 2026-04-23  
**Host:** compute10  
**Goal:** GCHighMemPercent threshold(60/75/90)에 따른 GC pause 감소 효과 정량화. ctrl(무제한)과 비교.

---

## 1. 실험 개요

두 클라이언트에 대해 동일한 workload를 걸고, heap 제한 + GC threshold를 변경하며 GC 동작을 비교.

| 항목 | Besu | Nethermind |
|------|------|-----------|
| 런타임 | JVM 21 (G1GC) | .NET CLR 10.0.5 |
| LASS 메커니즘 | E-Spill (TxPool → RocksDB 오프로드) | CLR `GCHighMemPercent` |
| Heap 제한 | `-Xms1g -Xmx1g` (고정) | `DOTNET_GCHeapHardLimit=1000000000` |
| ctrl 조건 | 기본 Besu 24.1.1 (heap 무제한) | heap 제한 없음, 기본 CLR GC |
| 실험 variants | ctrl, LASS-60, LASS-75, LASS-90 | ctrl, LASS-60, LASS-75, LASS-90 |
| 반복 횟수 | 5 runs × 4 variants = 20 runs | 5 runs × 4 variants = 20 runs |

---

## 2. LASS 설정 상세

### 2-1. Besu (E-Spill 메커니즘)

Besu의 LASS는 TxPool 내 트랜잭션을 RocksDB로 spill하여 heap 사용량을 줄이는 방식.

| Variant | activation | deactivation | consecutive_samples |
|---------|------------|-------------|---------------------|
| ctrl | — | — | — |
| LASS-60 | 0.60 (600MB) | 0.45 (450MB) | 1 |
| LASS-75 | 0.75 (750MB) | 0.60 (600MB) | 1 |
| LASS-90 | 0.90 (900MB) | 0.75 (750MB) | 1 |

- `activation`: heap 사용률이 이 값을 넘으면 E-Spill 시작
- `deactivation`: heap 사용률이 이 값 아래로 내려오면 E-Spill 중단
- `consecutive_samples=1`: 임계값 초과 1회 샘플만으로 즉시 activation

JVM 추가 플래그 (전 variants 공통):
```
-Xms1g -Xmx1g
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:G1MaxNewSizePercent=90
-XX:G1NewSizePercent=20
-Xlog:gc*:file=besu_gc.log:time,uptime,level,tags
```

**Binary:** `besu-source/build/install/besu/bin/besu` (commit `9b0e38f`)  
**ctrl binary:** `besu-24.1.1/bin/besu` (stock release)

### 2-2. Nethermind (CLR GCHighMemPercent 메커니즘)

Nethermind의 LASS는 CLR 환경 변수로 GC 공격성을 높이는 방식. heap hard limit 1GB를 설정하면, `GCHighMemPercent` 임계값 이상에서 CLR이 더 공격적으로 GC를 수행.

| Variant | DOTNET_GCHeapHardLimit | DOTNET_GCHighMemPercent | 의미 |
|---------|----------------------|------------------------|------|
| ctrl | 미설정 | 미설정 | 기본 CLR GC (heap 무제한) |
| LASS-60 | 1,000,000,000 (1GB) | 60 | heap 60% (600MB) 도달 시 공격적 GC |
| LASS-75 | 1,000,000,000 (1GB) | 75 | heap 75% (750MB) 도달 시 공격적 GC |
| LASS-90 | 1,000,000,000 (1GB) | 90 | heap 90% (900MB) 도달 시 공격적 GC |

환경 변수는 `COMPlus_` 접두사로도 동시 설정 (레거시 호환):
```bash
export DOTNET_GCHeapHardLimit=1000000000
export COMPlus_GCHeapHardLimit=1000000000
export DOTNET_GCHighMemPercent=60   # or 75, 90
export COMPlus_GCHighMemPercent=60
export DOTNET_EnableDiagnostics=1
```

NM 설정 파일: `nethermind-caliper-config/caliper_nethdev_cfg.json`  
주요 항목:
- `DiagnosticMode: MemDb` — 상태 트라이를 메모리에만 저장 (RocksDB 미사용)
- `TxPool.Size: 4096`
- `MemoryHint: 512000000` (512MB — TxPool size 4096 허용에 필요)
- `Mining.Enabled: true`, `Merge.Enabled: false` (NethDev instant miner)

**Binary:** `nethermind/artifacts/bin/Nethermind.Runner/release/nethermind.dll` (commit `68b3cf7d3f`)  

**중요 코드 수정:** `NethDevBlockProducerTxSourceFactory.cs`에서 `.ServeTxsOneByOne()` 제거  
→ 블록당 1 tx 제한 해제, 476 txs/block 배치 마이닝 가능

---

## 3. Workload 설정

### 3-1. 공통 스마트 컨트랙트

**StateBloater.sol**: `bloat(startIdx, count)` 호출 시 `heavyStorage[i] = i` 를 `count`개 저장.  
각 트랜잭션마다 200개의 새 스토리지 슬롯을 기록 → state trie를 빠르게 bloat시켜 heap 압박.

배포 주소: `0xF2E246BB76DF876Cef8b38ae84130F4F55De395b` (chainId 99, NethDev)

### 3-2. Caliper 설정

| 항목 | Besu | Nethermind |
|------|------|-----------|
| 파일 | `benchconfig-harsh-probe.yaml` | `benchconfig-nm-sensitivity.yaml` |
| Rate control | fixed-rate | fixed-rate |
| **TPS** | **1500 TPS** | **150 TPS** |
| Duration | 600s | 600s |
| Workers | 30 | 30 |
| slotsPerTx | 200 | 200 |
| txTimeout | 60s | 60s |

> **NM TPS가 150인 이유**: NethDev miner는 블록 타임스탬프 최소 1초 제약으로 최대 1 블록/초. 배치 마이닝 후 실효 drain rate ~240 TPS. 1500 TPS 입력 시 TxPool 포화(FeeTooLowToCompete 오류) 발생 → 150 TPS로 조정.

### 3-3. Worker 주소 할당

Caliper 30 workers는 HD wallet에서 파생된 각기 다른 주소 사용:
- Seed: `0x3f841bf589fdf83a521e55d51afddc34fa65351161eead24f064855fc29c9580`
- 경로: `m/44'/60'/{workerIndex}'/0/0` (workerIndex = 0..29)
- GasPrice: 1 Gwei (명시적 설정, `eth_gasPrice()` RPC 호출 방지)

---

## 4. GC 메트릭 수집

### 4-1. Besu

JVM GC 로그 (`-Xlog:gc*`) 파싱:
- **GC Event Count**: Young + Full + Mixed GC 횟수
- **Total GC Time (ms)**: STW pause 누적 합
- **Full GC Count**: Full GC (major collection) 횟수
- **Max GC Pause (ms)**: 단일 pause 최댓값
- **LASS activations**: E-Spill 발동 횟수
- **Peak heap %**: 최대 heap 사용률

분석 스크립트: `scripts/analyze_besu_sensitivity.py`

### 4-2. Nethermind

dotnet-trace + 자체 C# 파서 사용:
```bash
dotnet-trace collect \
  --process-id <nm_pid> \
  --providers "Microsoft-Windows-DotNETRuntime:0x1:5" \
  --output gc_trace.nettrace
```

파서: `gc-collector/publish/NettraceGcParser.dll`  
(Microsoft.Diagnostics.Tracing.TraceEvent 라이브러리 사용)

수집 메트릭:
- **gen0/1/2_gc_count**: 세대별 GC 횟수
- **total_pause_ms**: GCSuspendEE ~ GCRestartEE 구간 누적 합
- **avg_pause_ms**: pause당 평균 시간

> dotnet-counters는 .NET 10.0.5와 프로토콜 비호환 ("Waiting for initial payload...") → dotnet-trace로 대체

분석 스크립트: `scripts/analyze_nm_sensitivity.py`

---

## 5. 결과 요약

### 5-1. Besu (5 runs × 4 variants, TPS=1500)

| Metric | ctrl | LASS-60 | LASS-75 | LASS-90 |
|--------|------|---------|---------|---------|
| GC Events (mean) | 4,303 ± 459 | 2,461 ± 1,111 | 1,749 ± 524 | 3,992 ± 812 |
| Total GC Time (ms) | 621,063 ± 4,370 | 495,223 ± 206,561 | 482,370 ± 187,311 | 655,872 ± 31,922 |
| Full GC Count | 1,080 ± 109 | 990 ± 638 | 618 ± 282 | 1,447 ± 519 |
| Max GC Pause (ms) | 956 ± 179 | 1,150 ± 573 | 1,353 ± 277 | 922 ± 402 |
| LASS activations | 0 | 2.0 ± 0.7 | 2.6 ± 0.5 | 0.6 ± 0.9 |
| **Δ GC Events** | — | **↓ 42.8%** | **↓ 59.3%** | ↓ 7.2% |
| **Δ Total GC Time** | — | **↓ 20.3%** | **↓ 22.3%** | ↑ 5.6% |
| **Δ Full GC** | — | ↓ 8.4% | **↓ 42.8%** | ↑ 34.0% |

### 5-2. Nethermind (5 runs × 4 variants, TPS=150)

| Metric | ctrl | LASS-60 | LASS-75 | LASS-90 |
|--------|------|---------|---------|---------|
| Total GC Events (mean) | 34 ± 1 | 32 ± 2 | 33 ± 1 | 33 ± 1 |
| Total Pause (ms) | 23,731 ± 2,010 | 15,028 ± 1,225 | 16,123 ± 1,200 | 16,439 ± 1,113 |
| Gen2 GC Count | 12 ± 1 | 12 ± 1 | 12 ± 1 | 12 ± 0 |
| Avg Pause/event (ms) | 615 ± 45 | 393 ± 41 | 409 ± 26 | 414 ± 32 |
| Max Tx Latency (s) | 8.4 ± 1.2 | 12.1 ± 9.8 | 20.5 ± 4.8 | 22.6 ± 2.8 |
| **Δ Total Pause** | — | **↓ 36.7%** | **↓ 32.1%** | **↓ 30.7%** |
| **Δ Avg Pause/event** | — | ↓ 36.0% | ↓ 33.4% | ↓ 32.7% |
| **Δ Tx Max Latency** | — | ↑ 44% | ↑ 145% | ↑ 168% |

---

## 6. 핵심 발견

### GC pause 감소 효과
- **Besu**: LASS-75가 최적 — GC 이벤트 -59%, Full GC -43%, Total GC Time -22%
- **Nethermind**: LASS-60이 최적 — Total Pause -37%. 세 threshold 모두 30-37% 범위로 수렴

### LASS-90의 역설
- **Besu LASS-90**: activation 빈도 0.6회/run으로 낮아 효과 미미. Full GC +34% (역효과)
- **Nethermind LASS-90**: 감소 유지(-31%)이나 tx 지연 +168%로 실용성 낮음

### 클라이언트별 LASS 작동 방식 차이
| | Besu | Nethermind |
|--|------|-----------|
| 감소 방식 | GC 이벤트 횟수 자체 감소 (-59%) | GC 이벤트 수 불변, pause duration 감소 (-37%) |
| Threshold 민감도 | 높음 (60→75→90 효과 차이 큼) | 낮음 (세 threshold 유사한 효과) |
| 부작용 | Max GC pause 증가 (+20~42%) | Tx latency 증가 (+44~168%) |

### 최적 threshold 권고
- **Besu**: LASS-75 (GC count와 Full GC 감소 균형 최적)
- **Nethermind**: LASS-60 (가장 공격적인 GC 제어, tx latency 영향 상대적으로 최소)

---

## 7. 파일 위치

```
experiments/lass_sensitivity/
  README.md                          ← 이 파일

results/validation_caliper_1g/
  20260422_133356_caliper5x5/        ← Besu ctrl×5, lass75×5
  20260422_160143_besu_sensitivity/  ← Besu lass60×5, lass90×5
    analysis.log                     ← 통합 분석 리포트
    final_besu_sensitivity_1GB.md

results/validation_nethermind/
  20260423_114856_nm_sensitivity/    ← NM ctrl×5, lass60×5, lass75×5, lass90×5
    analysis.log                     ← 통합 분석 리포트
    final_nethermind_evaluation_1GB.md
    {variant}_{n}/
      gc_trace.nettrace              ← dotnet-trace raw data
      gc_summary.txt                 ← NettraceGcParser 출력
      caliper_console.log            ← Caliper TPS/latency
      nm_console.log                 ← Nethermind stdout

scripts/
  run_caliper_nm_sensitivity.sh      ← NM 20-run 자동화 스크립트
  analyze_nm_sensitivity.py          ← NM 결과 분석
  analyze_besu_sensitivity.py        ← Besu 결과 분석

gc-collector/
  publish/NettraceGcParser.dll       ← nettrace → gc_summary.txt 파서 (C#)

final_besu_sensitivity_1GB.md        ← Besu 최종 리포트 사본
final_nethermind_evaluation_1GB.md   ← NM 최종 리포트 사본
```
