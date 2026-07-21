# E-Spill Baseline Testing Quick Start Guide

## Overview

This guide helps you run baseline performance tests for Hyperledger Besu before implementing the e-spill algorithm. The baseline establishes current GC overhead, transaction latency, and jitter metrics.

## Prerequisites

- Hyperledger Besu 24.1.1 installed at `/home/yeochan.yoon/besu-24.1.1`
- Node.js and Hyperledger Caliper v0.4.2
- Python 3 for analysis scripts
- At least 90GB RAM available for JVM heap

## Quick Start

### 1. Deploy the StateBloater Contract (First Time Only)

If you haven't deployed the contract yet:

```bash
cd /home/yeochan.yoon/caliper-stress-test
node manual_deploy.js
```

This will deploy the StateBloater contract and update `networkconfig.json` with the contract address.

### 2. Run a Single Test (Recommended for First Run)

Start with the low intensity test to verify everything works:

```bash
./scripts/run_baseline_tests.sh --only low
```

This will:
- Start Besu in dev mode with GC logging
- Run 200 tx/s for 5 minutes
- Collect GC metrics and latency data
- Generate analysis reports

**Expected Duration**: ~8-10 minutes

### 3. Run Full Baseline Suite

To run all three intensity levels:

```bash
./scripts/run_baseline_tests.sh
```

This runs:
- **Low intensity**: 200 tx/s for 5 minutes
- **Medium intensity**: 500 tx/s for 10 minutes  
- **High intensity**: 1000 tx/s for 15 minutes

**Expected Duration**: ~45-60 minutes total

### 4. Review Results

Results are saved in `results/`:

```
results/
├── low_intensity/
│   ├── gc_logs/              # G1 GC log files
│   ├── caliper_reports/      # Caliper HTML reports
│   ├── gc_events.csv         # Parsed GC events
│   ├── latency.csv           # Transaction latencies
│   └── besu_console.log      # Besu output
├── medium_intensity/
│   └── ...
└── high_intensity/
    └── ...
```

## Manual Testing Steps

If you prefer to run steps manually:

### Step 1: Start Besu

```bash
./scripts/start_besu_baseline.sh
```

Wait for: `Besu is ready for baseline testing!`

### Step 2: Deploy Contract (if needed)

```bash
node manual_deploy.js
```

### Step 3: Run Caliper Benchmark

Choose an intensity level:

```bash
# Low intensity (200 tx/s, 5 min)
npx caliper launch manager \
  --caliper-workspace ./ \
  --caliper-benchconfig benchconfig-low.yaml \
  --caliper-networkconfig networkconfig.json

# Medium intensity (500 tx/s, 10 min)
npx caliper launch manager \
  --caliper-workspace ./ \
  --caliper-benchconfig benchconfig-medium.yaml \
  --caliper-networkconfig networkconfig.json

# High intensity (1000 tx/s, 15 min)
npx caliper launch manager \
  --caliper-workspace ./ \
  --caliper-benchconfig benchconfig-high.yaml \
  --caliper-networkconfig networkconfig.json
```

### Step 4: Analyze Results

Analyze GC behavior:

```bash
python3 scripts/monitor_gc.py baseline_gc_20260127_HHMMSS.log
```

Analyze transaction latency:

```bash
python3 scripts/monitor_latency.py report.html
```

### Step 5: Stop Besu

```bash
./scripts/stop_besu.sh
```

## Understanding the Metrics

### GC Overhead Ratio

The **key metric** for e-spill:

- **< 10%**: Low GC pressure, workload is stable
- **10-20%**: Moderate pressure, e-spill would start spilling
- **> 20%**: High pressure, significant GC overhead (target for e-spill)

From the e-spill paper: **10% is the optimal threshold**

### Transaction Latency

Important metrics:
- **Mean**: Average transaction confirmation time
- **P99**: 99th percentile - how long do the slowest 1% of transactions take?
- **Jitter (CV)**: Coefficient of variation - consistency of latency

### Correlation

The goal is to show that **GC pauses cause latency spikes**. After implementing e-spill, we expect:
- Lower GC overhead ratio
- Reduced P99 latency
- More consistent latency (lower jitter)

## Troubleshooting

### Besu Won't Start

Check logs:
```bash
tail -50 data_bl/besu_console.log
```

Common issues:
- Port 8545/8546 already in use: `lsof -i :8545`
- Insufficient memory: Check available RAM

### Contract Deployment Fails

Ensure Besu is running and responsive:
```bash
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8545
```

### Low GC Pressure in Tests

If GC overhead is very low (< 2%), the workload isn't stressful enough:
- Increase transaction rate in benchmark configs
- Increase `slotsPerTx` in workload arguments
- Run for longer duration

## Next Steps

After collecting baseline data:

1. **Analyze trends** across intensity levels
2. **Document methodology** for research paper
3. **Implement e-spill** algorithm in Besu
4. **Re-run tests** and compare against baseline
5. **Calculate improvements** (speedup, GC reduction, jitter reduction)

## Research Paper Sections

The baseline tests provide data for:

### Experimental Setup Section
- Hardware specifications
- Software versions (Besu, JVM, Caliper)
- Test parameters
- Workload characteristics

### Baseline Performance Section
- Current GC overhead vs transaction rate
- Latency distributions at different loads
- Correlation between GC events and latency spikes
- Identification of performance bottlenecks

### Evaluation Methodology
- Metrics definitions
- Reproducibility instructions
- Statistical analysis methods

---

**Questions or Issues?**

Check the implementation plan: `.gemini/antigravity/brain/.../implementation_plan.md`
