# LASS 구현 규모 (LOC) 및 Hook 위치

리뷰어/논문 보강용: LASS 구현 시 실제 코드 수정 규모와 훅 위치를 정리한 문서입니다.

---

## 1. 요약 표 (논문/리뷰어용)

| 클라이언트 | 신규/수정 LOC (대략) | Hook 위치 | 비고 |
|-----------|----------------------|-----------|------|
| **Besu** | **~330 LOC 신규** + 통합 수정 | **Transaction pool** (`PendingTransactions` / `AbstractPrioritizedTransactions`) | 신규: MemoryPressureMonitor 176, TransactionSpillStorage 155. 통합 시 6–8개 파일 수정 추정. |
| **Nethermind** | **전용 LASS/state-spill 없음** (기존 GC/LOH 코드 **~475 LOC**) | **Block production / Engine API** (NoGCRegion → 블록 후 scheduled GC, LOH CompactOnce) | 별도 state spill 모듈 없음. Merge Plugin GC + Core GCScheduler로 LOH 안정화. |

---

## 2. Besu — 상세

### 2.1 신규 추가 클래스 (이 레포 기준 문서화된 수치)

- **MemoryPressureMonitor.java**  
  - 경로: `org.hyperledger.besu.ethereum.eth.transactions`  
  - **176 LOC**  
  - 역할: JVM GC overhead 실시간 모니터링, 활성/비활성 임계값(예: 8% / 5%)으로 spill 여부 판단.

- **TransactionSpillStorage.java**  
  - 경로: `org.hyperledger.besu.ethereum.eth.transactions`  
  - **155 LOC**  
  - 역할: RocksDB 기반 spill 저장, RLP 인코딩/디코딩, spill/restore 메트릭.

- **합계: ~331 LOC** (신규 클래스만).

### 2.2 Hook / 통합 위치

- **실제 구현(이 레포/가이드 기준):** **Transaction pool** 계층.
  - 수정 대상: `PendingTransactions` 또는 `AbstractPrioritizedTransactions` / `LayeredPendingTransactions` 등.
  - 통합 내용: `MemoryPressureMonitor` + `TransactionSpillStorage` 주입, 주기적 체크 스레드, `spillPendingTransactions()` / `restoreSpilledTransactions()` 호출.
  - 문서(E_SPILL_STATUS, E_SPILL_IMPLEMENTATION_GUIDE) 기준으로는 **WorldStateUpdater가 아닌, tx pool**에서 pending tx를 spill하는 구조.

- **논문 개념(LASS):**  
  논문에서는 “ephemeral state objects”, “Accumulator”, “state-trie” 기반 **state spilling**을 말하므로, 개념적으로는 **WorldStateUpdater / state accumulator** 쪽 hook도 가능.  
  **실제로 논문 실험에 사용한 것이 tx-pool spill인지, state-layer spill인지에 따라 “Hook 위치” 문구를 아래 중에서 선택해 쓰시면 됩니다.**

  - **Tx-pool 구현을 썼다면:**  
    “Hook location: **transaction pool** (`PendingTransactions` / `AbstractPrioritizedTransactions`), in package `org.hyperledger.besu.ethereum.eth.transactions`.”

  - **State-layer 구현을 썼다면:**  
    “Hook location: **state / accumulator** (e.g. `WorldStateUpdater` or the layer that holds ephemeral state diffs before commit).”

### 2.3 전체 수정 규모 (추정)

- 신규: **~330 LOC** (위 두 클래스).
- 통합: 가이드에서 “6–8개 소스 파일 수정”, “LayeredPendingTransactions 등 여러 레이어” 언급 → **추가로 수백 LOC 수준** 가능.  
- **총 Besu: 대략 500–800 LOC** (신규 + 통합, 구현 세부에 따라 달라짐).

---

## 3. Nethermind — 상세

- **경로:** `/home/yeochan.yoon/nethermind` 기준으로 확인함.
- **전용 LASS/state-spill 모듈 없음:** `*Spill*.cs`, `*LASS*.cs` 파일 없음. WorldState/state accumulator에 대한 spill 저장·복원 코드도 없음.
- **기존 GC/LOH 관련 코드 (논문의 Nethermind “LASS” 효과에 대응 가능):**
  - **Nethermind.Merge.Plugin/GC/**  
    - **GCKeeper.cs** — 195 LOC: 블록 처리 중 `TryStartNoGCRegion`, 블록 후 `ScheduleGC`에서 Gen2 + Full compaction 시 **LOH CompactOnce** 설정 (`GCSettings.LargeObjectHeapCompactionMode`).  
    - **IGCStrategy.cs** — 36 LOC (enum 포함).  
    - **NoSyncGcRegionStrategy.cs** — 31 LOC.  
    - **NoGCStrategy.cs** — 13 LOC.
  - **Nethermind.Core/GC/GCScheduler.cs** — 201 LOC (LOH compaction 설정 포함).
  - **합계: ~476 LOC** (신규 LASS가 아니라 기존 Merge/block-latency·LOH 제어용).
- **Hook 위치:** **Block production / Engine API.**  
  - NoGCRegion으로 블록 처리 구간에서 GC 억제 → 블록 처리 후 `PostBlockGcDelayMs` 뒤 scheduled GC (SweepMemory, CompactMemory).  
  - Gen2 + Full이면 `GCLargeObjectHeapCompactionMode.CompactOnce`로 LOH 정리.  
  - **WorldStateUpdater·state-spill 훅 없음.**
- **설정:** `IMergeConfig` / `MergeConfig`: `SweepMemory` (GcLevel), `CompactMemory` (GcCompaction), `PrioritizeBlockLatency`, `PostBlockGcDelayMs`, `CollectionsPerDecommit`.  
  논문의 Nethermind 5.7% throughput 개선은 이 **기존 GC/LOH 옵션 조합**(예: SweepMemory=Gen2, CompactMemory=Full)으로 재현했을 가능성이 큼.
- 이 레포(**caliper-stress-test**)에는 **Ban 실험용** 코드만 별도 존재: **BanTransactionFilter.cs** (~40 LOC), **GasDensityReputation.cs** (stub).

---

## 4. 논문/리뷰어에 쓸 수 있는 문장 예시

- **Implementation size:**  
  “For Besu, LASS adds two new components (**MemoryPressureMonitor**, **TransactionSpillStorage**) totaling approximately **330 LOC**, integrated into the **transaction pool** (pending transactions layer). Full integration touches the pool’s layered design (estimated 6–8 files). For Nethermind, we did not add a separate state-spill module; the reported gains use the existing **Merge Plugin GC** and **GCScheduler** (~476 LOC) that prioritize block latency (NoGCRegion during block processing) and optionally compact the **large object heap (LOH)** after blocks (SweepMemory/CompactMemory).”

- **Hook location (Besu, tx-pool 기준):**  
  “The Besu hook is in the **transaction pool** (`org.hyperledger.besu.ethereum.eth.transactions`): we check memory pressure periodically and spill/restore pending transactions via a RocksDB-backed store, without modifying the core execution or WorldStateUpdater path.”

- **Hook location (Nethermind):**  
  “For Nethermind, the intervention is at **block production / Engine API**: the client suppresses GC during block processing (NoGCRegion) and runs scheduled GC with LOH compaction afterward (GCSettings.LargeObjectHeapCompactionMode). No WorldState or state-spill hook is used.”

---

## 5. 참고 — 출처

- **Besu** LOC·경로: `E_SPILL_STATUS_AND_OPTIONS.md`, `E_SPILL_IMPLEMENTATION_GUIDE.md`. 통합: Step 3 (Modify Transaction Pool), LayeredPendingTransactions. 실제 구현: Besu 소스는 `/home/yeochan.yoon/besu-source/` 등 별도 경로에 있을 수 있음 (이 레포에는 미포함).
- **Nethermind:** 소스 경로 `/home/yeochan.yoon/nethermind` 기준으로 GC/LOH 관련 파일 직접 확인 (Merge.Plugin/GC/*.cs, Nethermind.Core/GC/GCScheduler.cs). 전용 LASS/state-spill 검색: `*Spill*`, `*LASS*`, WorldState spill, LOH — spill 전용 모듈 없음.

논문에 기입할 때는 **실제로 실험에 사용한 구현**이 tx-pool인지 state-layer인지에 맞춰 “Hook 위치”와 LOC 설명을 위에서 선택해 사용하시면 됩니다.
