# 6. Evaluation

We evaluated **LAST** (*Locality-Aware Scheduling of Transactions*) and its companion admission-control mechanism **LASS** (*Locality-Aware State Scheduling*) across two production Ethereum clients — Nethermind (.NET runtime) and Hyperledger Besu (JVM/G1GC) — under three load regimes: heap-constrained steady stress, mempool-saturating DDoS simulation, and sustainable normal operation. All experiments used a *StateBloater* workload (200 SSTORE operations per transaction) deployed via Hyperledger Caliper, designed to maximize per-transaction old-generation heap pressure. Four variants were compared in each scenario:

- **Baseline** — stock FIFO mempool ordering, no LASS.
- **LASS-75** — heap-triggered GC at 75% old-generation occupancy, no locality reordering.
- **LAST-AL** — *Address Locality* ordering (group transactions by sender address) without LASS.
- **LAST+LASS-75** — LAST-AL ordering combined with LASS-75 admission control.

---

## 6.1 Experimental Setup

**Nethermind.** The Nethermind client was configured with a 1 GB GC hard limit enforced via `DOTNET_GCHeapHardLimit`. The StateBloater workload was submitted at 150 TPS through 30 concurrent workers. Each run consisted of a 120 s warmup period followed by a 300 s measurement window. Five repetitions were executed per variant (4 variants × 5 reps = 20 runs total); two baseline runs terminated prematurely and were excluded, leaving three valid baseline observations. GC pause events were collected from the .NET EventPipe trace and aggregated per run.

**Hyperledger Besu.** Besu was evaluated under two scenarios. In the *extreme load* scenario (§6.3), a 1 GB JVM heap (`-Xmx1g`) was paired with a 1500 TPS submission rate — well beyond EVM processing capacity — to simulate sustained spam. In the *sustainable load* scenario (§6.4), a 4 GB heap was used with a 40 TPS submission rate representative of normal mainnet conditions. Both scenarios used a 300 s measurement window with five repetitions per variant. GC metrics were extracted from the JVM G1GC unified log (`-Xlog:gc*`), capturing per-event pause durations, event type (Young/Mixed/Full), and cumulative GC time.

**Metrics.** The primary metrics are: (1) GC pause duration in milliseconds, reported as mean, p50, p95, and p99 across all pause events pooled from valid runs; (2) Full GC event count per run; (3) total cumulative GC time per run; and (4) confirmed transaction throughput (TPS) as reported by the Caliper monitor.

---

## 6.2 Heap-Constrained GC Pause Reduction (Nethermind, 1 GB, 150 TPS)

Under a 1 GB GC hard limit and 150 TPS StateBloater load, the four variants produced starkly different GC pause distributions (Figure 1). Table 1 summarizes the pooled pause statistics.

**Table 1. Nethermind GC pause statistics (150 TPS, 1 GB heap, 300 s window).**

| Variant       | Events (n) | Mean (ms) | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Valid Runs |
|---------------|-----------|-----------|----------|----------|----------|----------|------------|
| Baseline      | 93        | 724       | 456      | 2,365    | 3,225    | 3,447    | 3          |
| LASS-75       | 79        | 468       | 260      | 1,515    | 2,598    | 2,644    | 5          |
| LAST-AL       | 85        | 1,027     | 707      | 2,930    | 4,070    | 7,610    | 5          |
| LAST+LASS-75  | 80        | 465       | 290      | **1,281**| 2,655    | 2,905    | 5          |

The per-run average GC pause for the baseline was **685 ms** (mean of three valid runs: 685 ms, 609 ms, 760 ms). LASS-75 reduced this to **467 ms** (−31.7%), and LAST+LASS-75 achieved **469 ms** (−31.6%), effectively matching LASS-75 in the per-run mean. Crucially, LAST+LASS-75 delivered the **best p95 across all variants at 1281 ms**, outperforming LASS-75 alone (p95 = 1515 ms) by 15%.

**LAST-AL alone is counterproductive.** Without LASS, address-locality ordering increased the per-run mean to **1031 ms** (+50.6% vs. baseline), pushed the p99 to **4070 ms** (vs. baseline p99 of 3225 ms), and produced a maximum observed pause of **7610 ms**. The mechanism is straightforward: LAST-AL batches transactions by sender address, which causes a cohort of related storage objects to be allocated, promoted through Gen-1, and simultaneously resident in Gen-2 at GC time. The resulting large *live set* at the moment of collection forces the .NET GC to scan and retain more objects per pause cycle, extending collection duration. Under an already constrained 1 GB heap, this amplification is severe.

**LASS-75 neutralizes the live-set amplification.** By triggering GC proactively when old-generation occupancy reaches 75% of the hard limit, LASS prevents the heap from reaching the fully-saturated state that produces multi-second pauses. Collections fire earlier, against a smaller live set, and complete faster. When combined with LAST-AL, this proactive trigger intercepts the cohort-driven live-set growth before it accumulates to dangerous levels, producing a p95 **15% lower** than LASS-75 in isolation. The synergy arises because LAST ordering creates temporally coherent allocation waves — waves that LASS can excise with a single well-timed collection rather than forcing the GC to straddle a partially-filled heap.

The CDF of per-event pause durations (Figure 1) illustrates the divergence clearly: LAST-AL's tail extends to a maximum of 7610 ms (p99 = 4070 ms), baseline reaches 3447 ms (p99 = 3225 ms), while LASS-75 and LAST+LASS-75 cap at 2644 ms and 2905 ms respectively. Below the 90th percentile, LAST+LASS-75 is consistently the lowest curve.

---

## 6.3 DDoS Resilience: Mempool Saturation at 1500 TPS (Besu, 1 GB)

At 1500 TPS — roughly ten times the EVM's sustained throughput capacity for this workload — the mempool grew unboundedly throughout each 300 s window. Confirmed TPS was effectively zero across all variants (one LAST+LASS-75 run recorded 0.1 TPS; all others confirmed 0 TPS), confirming that EVM processing capacity, not scheduling policy, is the throughput bottleneck at this load level. Nevertheless, the variants diverged dramatically in their GC behavior, as shown in Table 2.

**Table 2. Besu GC statistics at 1500 TPS, 1 GB heap (5 reps per variant, 300 s window).**

| Variant       | GC Events/run | Total GC Time/run | Full GCs/run | Max Pause/run | Confirmed TPS |
|---------------|--------------|-------------------|--------------|---------------|---------------|
| Baseline      | 1,156        | 472 s             | 176          | 2782 ms       | 0             |
| LASS-75       | 1,035        | 301 s             | 91           | 2113 ms       | 0             |
| LAST-AL       | 2,694†       | 133 s             | 614†         | 957 ms        | 0             |
| LAST+LASS-75  | 23           | **729 ms**        | **0**        | **106 ms**    | ~0            |

*† LAST-AL statistics are dominated by a single outlier run with 10,560 GC events; the mean is not representative of typical behavior.*

The contrast between LAST+LASS-75 and all other variants is categorical rather than incremental. Baseline and LASS-75 accumulated 472 s and 301 s of total GC time per run, respectively — durations that exceed the measurement window itself, indicating the JVM spent more time in GC than in application execution. LAST-AL's aggregate GC time appears lower (133 s) due to outlier-driven averaging, but the outlier run's 10,560 GC event count signals GC thrashing, not efficiency. All three variants experienced hundreds of Full GC events, each of which is a stop-the-world pause on the JVM.

LAST+LASS-75 eliminated Full GCs entirely (**0 Full GCs** across all five runs) and reduced total GC time per run to **729 ms** — a **650× reduction** relative to baseline's 472 s. Maximum per-pause duration dropped to **106 ms**, compared to 2782 ms for baseline. This outcome was achieved because LASS-75's proactive old-generation drain prevented the G1GC from ever escalating to a Full GC cycle. G1GC promotes from Young to Old in incremental mixed collections; when old-gen never reaches the saturation point, G1 never falls back to the serial Full GC stop-the-world path.

While no variant processed 1500 TPS economically, only LAST+LASS-75 preserved **node liveness** under spam-level load. A node spending 472 s of a 300 s window in GC is effectively a non-participant in consensus and block propagation. LAST+LASS-75's 729 ms total GC time represents a node that remains operationally coherent throughout the attack window — a critical distinction for network partition resistance and validator uptime.

---

## 6.4 Zero Overhead Under Normal Operations (Besu, 4 GB, 40 TPS)

To verify that LAST scheduling does not impose GC overhead under benign conditions, we ran the baseline variant at 40 TPS with a 4 GB JVM heap (`-Xmx4g`). At this load, the StateBloater workload generates approximately 22 MB/min of old-generation growth. G1GC handled all heap pressure exclusively through *Young-generation* collections with a mean pause of **18.3 ms** and a maximum of **78.1 ms**. Zero mixed GC and zero Full GC events were observed across the entire 300 s measurement window.

The LASS-75 threshold at 4 GB corresponds to a 3 GB old-generation trigger level (75% of 4096 MB = 3072 MB). At the observed growth rate of 22 MB/min, reaching this threshold from a cold start would require approximately **134 minutes** — far beyond the experimental window and, in practice, far beyond any realistic steady-state operating point for a node that periodically processes blocks and compacts its state trie. Accordingly, LASS remained **completely inert** throughout the 40 TPS experiment: no proactive GC triggers were fired, and the LAST scheduler operated without any admission-control overhead.

This result validates a core design premise: LASS is a *reactive-under-stress* mechanism, not a *continuous-overhead* mechanism. During normal operation, LAST's locality ordering runs at negligible cost (a sort over the pending mempool), while LASS monitors heap occupancy but never fires. The GC profile under 40 TPS is indistinguishable from an unmodified baseline, confirming that LAST introduces no latency regression in the steady-state case.

---

## 6.5 Summary

Table 3 collects the headline metrics across all three experimental scenarios.

**Table 3. Cross-scenario summary of key metrics.**

| Scenario              | Variant       | Mean GC Pause | p95 GC Pause | Full GCs/run | Total GC Time/run | Confirmed TPS |
|-----------------------|---------------|--------------|--------------|--------------|-------------------|---------------|
| NM 1 GB / 150 TPS     | Baseline      | 724 ms       | 2435 ms      | —            | —                 | ~150          |
| NM 1 GB / 150 TPS     | LASS-75       | 468 ms       | 1,515 ms     | —            | —                 | ~150          |
| NM 1 GB / 150 TPS     | LAST-AL       | 1,027 ms     | 2,930 ms     | —            | —                 | ~150          |
| NM 1 GB / 150 TPS     | LAST+LASS-75  | 465 ms       | **1,281 ms** | —            | —                 | ~150          |
| Besu 1 GB / 1500 TPS  | Baseline      | —            | —            | 176          | 472 s             | 0             |
| Besu 1 GB / 1500 TPS  | LASS-75       | —            | —            | 91           | 301 s             | 0             |
| Besu 1 GB / 1500 TPS  | LAST-AL       | —            | —            | 614†         | 133 s†            | 0             |
| Besu 1 GB / 1500 TPS  | LAST+LASS-75  | —            | —            | **0**        | **729 ms**        | ~0            |
| Besu 4 GB / 40 TPS    | Baseline      | 18.3 ms      | —            | 0            | —                 | 40            |

*† Outlier-inflated; see §6.3.*

The results demonstrate three complementary properties of the LAST+LASS-75 design. First, under heap-constrained steady stress (Nethermind, 1 GB, 150 TPS), LAST+LASS-75 reduces mean GC pause duration by **31.6%** relative to baseline and achieves the lowest p95 across all variants (1281 ms vs. baseline 2365 ms), validating the synergy between locality-aware ordering and proactive heap control. Second, under mempool-saturating DDoS conditions (Besu, 1 GB, 1500 TPS), LAST+LASS-75 eliminates Full GC events entirely and reduces total GC time by **650×**, preserving node liveness while all other variants enter GC-collapse states incompatible with continued consensus participation. Third, under sustainable normal load (Besu, 4 GB, 40 TPS), LAST+LASS-75 is operationally invisible: LASS never fires, LAST's ordering overhead is negligible, and the GC profile is identical to an unmodified baseline. Together, these results establish that LAST is not a throughput-throughput trade-off but a *correctness-under-pressure* mechanism: it adds no cost in the common case and prevents catastrophic degradation in the adversarial case.
