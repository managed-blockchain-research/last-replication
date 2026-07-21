"""
논문 Figure 3: CDF of Execution Latency (Besu / Nethermind, Baseline vs LASS)
- 겹치는 선이 보이도록 alpha 적용, LASS를 나중에 그려 위에 표시
"""
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns

# 1. 학술 논문 스타일 설정
plt.rcParams.update({
    'font.size': 14,
    'font.family': 'serif',
    'axes.labelsize': 15,
    'xtick.labelsize': 13,
    'ytick.labelsize': 13,
    'legend.fontsize': 13
})

# 2. 데이터 로드 (paper_cdf_latency.csv 컬럼: client, config, latency_ms)
csv_file_path = 'docs/paper_cdf_latency.csv'
df = pd.read_csv(csv_file_path, header=0)

# 컬럼명 통일 (기존 스크립트 호환)
df = df.rename(columns={'client': 'Client', 'config': 'Config', 'latency_ms': 'Latency'})
df['Config'] = df['Config'].astype(str).str.strip()
df['Latency'] = pd.to_numeric(df['Latency'], errors='coerce')
df = df.dropna(subset=['Latency'])

clients = df['Client'].unique()

# 3. 그래프 그리기
fig, axes = plt.subplots(1, len(clients), figsize=(6 * len(clients), 5.5))
if len(clients) == 1:
    axes = [axes]

colors = {'Baseline': '#E24A33', 'LASS': '#348ABD'}
linestyles = {'Baseline': '-', 'LASS': '--'}

# LASS를 나중에 그리면 위에 겹쳐져서 보임 (hue_order)
for ax, client_name in zip(axes, clients):
    client_data = df[df['Client'] == client_name]

    sns.ecdfplot(
        data=client_data,
        x='Latency',
        hue='Config',
        hue_order=['Baseline', 'LASS'],  # Baseline 먼저, LASS 나중에(위에)
        palette=colors,
        ax=ax,
        linewidth=2.5
    )

    # 선 스타일 + 투명도 적용 (겹쳐도 두 선 모두 보이게)
    for line in ax.lines:
        label = line.get_label()
        if label in linestyles:
            line.set_linestyle(linestyles[label])
        line.set_alpha(0.85)
        # LASS는 나중에 그려지므로 살짝 더 두껍게 해서 겹쳐도 보이게
        if label == 'LASS':
            line.set_linewidth(3.0)

    ax.set_title(client_name, fontweight='bold')
    ax.set_xlabel('Execution Latency (ms)')
    ax.set_ylabel('Cumulative Probability (CDF)')

    max_xlim = client_data['Latency'].quantile(0.995)
    ax.set_xlim(0, max_xlim)
    ax.grid(axis='both', linestyle='--', alpha=0.5)

# 범례
for ax in axes:
    if ax.get_legend():
        ax.get_legend().remove()

handles = [
    plt.Line2D([0], [0], color=colors['Baseline'], linestyle=linestyles['Baseline'], lw=2.5, alpha=0.85),
    plt.Line2D([0], [0], color=colors['LASS'], linestyle=linestyles['LASS'], lw=3.0, alpha=0.85)
]
labels = ['Baseline', 'LASS (Ours)']
fig.legend(handles, labels, loc='upper center', bbox_to_anchor=(0.5, 1.05), ncol=2, frameon=False)

plt.tight_layout()
plt.subplots_adjust(top=0.88)

plt.savefig('figure3_cdf_latency.svg', format='svg', bbox_inches='tight')
plt.savefig('figure3_cdf_latency.png', dpi=300, bbox_inches='tight')
plt.show()
