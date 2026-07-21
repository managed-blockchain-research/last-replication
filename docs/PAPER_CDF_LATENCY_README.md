# paper_cdf_latency.csv — 논문 CDF용 지연 시간 원본

**논문:** Mitigating the Latency Cliff in Managed Blockchain Clients (LASS)

이 CSV는 논문에서 사용한 **동일 출처**의 latency만 모은 raw 데이터입니다. CDF(Cumulative Distribution Function) 그리기용으로 사용하세요.

## 컬럼

| 컬럼 | 설명 |
|------|------|
| `client` | Besu \| Nethermind |
| `config` | Baseline \| LASS |
| `latency_ms` | 해당 트랜잭션 지연 시간 (ms), 성공(success=True) 건만 포함 |

## 데이터 출처 (논문과 동일)

| client | config | 원본 파일 | 행 수(성공만) |
|--------|--------|-----------|----------------|
| Besu | Baseline | `results/extreme/baseline_latency.csv` | 62,401 |
| Besu | LASS | `results/extreme/espill_latency.csv` | 62,155 |
| Nethermind | Baseline | `results/nethermind/gcdump-20260130_125919/baseline_pre_latency.csv` | 118,785 |
| Nethermind | LASS | `results/nethermind/gcdump-20260130_125919/espill_pre_latency.csv` | 125,616 |

- Besu: 논문의 96.2% GC overhead / 98.1% STW 감소 수치에 대응하는 run.
- Nethermind: 논문의 5.7% throughput 증가 수치에 대응하는 run.

## 재생성

```bash
python3 scripts/build_paper_cdf_latency_csv.py
```

## CDF 그리기 예시 (Python)

```python
import pandas as pd
import matplotlib.pyplot as plt

df = pd.read_csv("docs/paper_cdf_latency.csv")
for (client, config), g in df.groupby(["client", "config"]):
    s = g["latency_ms"].sort_values()
    plt.step(s, (1 + np.arange(len(s))) / len(s), label=f"{client} {config}")
plt.legend()
plt.xlabel("Latency (ms)")
plt.ylabel("CDF")
plt.show()
```
