# LAST source patch

- `besu-last/`: Besu 24.1.1 integration (variants: DISABLED, ADDRESS_LOCALITY,
  WORKING_SET_AFFINITY, HYBRID_FEE_LOCALITY). Includes the
  `reorderHybridWithWeights`/`reorderHybrid` O(n log n) comparator-recompute
  fix (precompute each candidate's score once, sort on the cached value) —
  see `main.tex` §eval:stress for context. Build scripts and patch notes
  included alongside the source.
- `nethermind-last/`: the Nethermind CLR port (`LastTxPoolTxSource.cs`).
  This file also implements the WSA/HFL/MATS/PREP variants used by the
  sibling papers that build on LAST — it is intentionally identical to the
  copy in the `mats` and `prep` branches of this repo family.
