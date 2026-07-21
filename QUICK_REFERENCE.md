# Quick Reference - E-Spill Baseline Testing

## Start/Stop Besu

```bash
# Start Besu (dev mode, GC logging enabled)
./scripts/start_besu_baseline.sh

# Stop Besu
./scripts/stop_besu.sh
```

## Deploy Contract (if needed)

```bash
python3 deploy_contract.py
```

Contract address will be auto-updated in `networkconfig.json`

## Run Tests

### Quick Test (30 seconds)
```bash
python3 quick_baseline_test.py
```

### Extended Tests

```bash
# Low intensity: 5 min @ 20 tx/s
python3 extended_baseline_test.py --config low

# Medium intensity: 10 min @ 50 tx/s
python3 extended_baseline_test.py --config medium

# High intensity: 15 min @ 100 tx/s (targets >10% GC overhead)
python3 extended_baseline_test.py --config high
```

### Custom Parameters
```bash
python3 extended_baseline_test.py \
  --duration 600 \
  --rate 75 \
  --slots 100 \
  --output results/custom/test
```

## Analyze Results

### GC Analysis
```bash
# Analyze specific GC log
python3 scripts/monitor_gc.py baseline_gc_20260127_112520.log

# Analyze latest GC log
python3 scripts/monitor_gc.py $(ls -t baseline_gc_*.log | head -1)

# Export to CSV
python3 scripts/monitor_gc.py baseline_gc_*.log results/gc_events.csv
```

### Latency Analysis
```bash
python3 scripts/monitor_latency.py results/low_intensity/baseline_latency.csv
```

## Key Metrics

### GC Overhead Ratio
**The critical metric for e-spill threshold:**
- < 5%: Very low pressure
- 5-10%: Moderate pressure
- **>10%: High pressure** ← E-spill should activate here
- >20%: Severe pressure

### Latency/Jitter
- **P99 latency**: How long do 1% slowest transactions take?
- **Jitter (CV)**: Coefficient of variation - consistency measure
- Lower is better for both

## Results Structure

```
results/
├── low_intensity/
│   ├── baseline_latency.csv
│   └── (copy GC logs here manually)
├── medium_intensity/
│   └── ...
└── high_intensity/
    └── ...
```

## Troubleshooting

### Besu won't start
```bash
# Check if already running
pgrep -f besu

# Check logs
tail -50 data_bl/besu_console.log

# Clean data and restart
rm -rf data_bl/* && ./scripts/start_besu_baseline.sh
```

### Contract errors
```bash
# Redeploy contract
python3 deploy_contract.py

# Check contract address matches in networkconfig.json
grep address networkconfig.json
```

### Low GC overhead
To trigger higher GC pressure:
- Increase `--rate` (more tx/s)
- Increase `--slots` (more memory per tx)
- Increase `--duration` (longer test)

## Expected Results for Research Paper

### Low Intensity (Baseline)
- GC overhead: ~2-5%
- Few GC events
- Stable latency

### High Intensity (Demonstrates Need for E-Spill)
- GC overhead: >10% (target: 15-20%)
- Frequent GC pauses
- Latency spikes correlate with GC events
- **This is where e-spill will show improvements**

## Commands Cheat Sheet

```bash
# Full workflow
./scripts/start_besu_baseline.sh
python3 deploy_contract.py
python3 extended_baseline_test.py --config high
python3 scripts/monitor_gc.py $(ls -t baseline_gc_*.log | head -1)
./scripts/stop_besu.sh

# One-liner quick test
./scripts/start_besu_baseline.sh && sleep 5 && python3 deploy_contract.py && python3 quick_baseline_test.py
```

## File Locations

- **Tests**: `extended_baseline_test.py`, `quick_baseline_test.py`
- **GC Logs**: `baseline_gc_*.log`
- **Results**: `results/*/`
- **Monitoring**: `scripts/monitor_gc.py`, `scripts/monitor_latency.py`
- **Besu Data**: `data_bl/`
- **Contract**: `StateBloater.json`, `networkconfig.json`

## For Research Paper

1. **Run all 3 intensity levels**
2. **Collect metrics**: GC overhead, latency distributions, jitter
3. **Create plots**: GC events vs time, latency vs time, overhead vs tx rate
4. **Document findings**: Which scenarios trigger >10% GC overhead?
5. **Implement e-spill** in Besu
6. **Re-run same tests** to show improvements
7. **Calculate improvements**: GC reduction %, latency improvement, jitter reduction

---

**Everything is ready!** You can start collecting baseline data for your e-spill research paper. 🚀
