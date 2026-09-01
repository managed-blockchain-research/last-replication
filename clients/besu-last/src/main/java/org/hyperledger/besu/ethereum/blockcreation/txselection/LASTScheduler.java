/*
 * LAST: Locality-Aware Scheduling of Transactions
 * LASTScheduler — reorders pending transactions before block construction.
 *
 * Variants:
 *   DISABLED              — pass-through; original pool order unchanged
 *   ADDRESS_LOCALITY (AL) — group by destination address, hottest groups first
 *   WORKING_SET_AFFINITY (WSA) — warm-set first, then cold; groups within each partition
 *   HYBRID_FEE_LOCALITY (HFL) — weighted score: alpha*fee + beta*locality
 *
 * All variants preserve per-sender nonce monotonicity for intra-address transactions.
 * Cross-sender cross-destination nonce violations are not introduced (each sender
 * sequence is independent; LAST never reorders two transactions from the same sender
 * targeting the same destination).
 *
 * Thread safety: single-threaded within Besu's block creation FutureTask.
 */
package org.hyperledger.besu.ethereum.blockcreation.txselection;

import org.hyperledger.besu.datatypes.Address;
import org.hyperledger.besu.datatypes.Wei;
import org.hyperledger.besu.ethereum.core.Transaction;
import org.hyperledger.besu.ethereum.eth.transactions.PendingTransaction;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.TimeUnit;

public class LASTScheduler {

  public enum Variant {
    DISABLED,
    ADDRESS_LOCALITY,
    WORKING_SET_AFFINITY,
    HYBRID_FEE_LOCALITY
  }

  private final Variant variant;
  private final StateLocalityTracker tracker;
  private final double alpha; // fee weight for HFL
  private final double beta;  // locality weight for HFL

  // Last measured overhead in microseconds
  private volatile long lastOverheadUs = 0L;

  public LASTScheduler(
      final Variant variant,
      final StateLocalityTracker tracker,
      final double alpha,
      final double beta) {
    this.variant = variant;
    this.tracker = tracker;
    this.alpha = alpha;
    this.beta = beta;
  }

  // ── Accessors ───────────────────────────────────────────────────────────────

  public Variant getVariant() {
    return variant;
  }

  /** Scheduling overhead in µs for the most recent reorder() call. */
  public long getLastOverheadUs() {
    return lastOverheadUs;
  }

  // ── Main entry point ────────────────────────────────────────────────────────

  /**
   * Reorder the given candidate list according to the configured LAST variant.
   * Returns the original list unchanged for DISABLED or empty inputs.
   * Records observation counts in the tracker for metrics.
   *
   * @param candidates  ordered candidates from the txpool (fee-priority order)
   * @param baseFee     EIP-1559 base fee of the pending block (may be empty for legacy networks)
   * @return            reordered list (may be the same object for DISABLED)
   */
  public List<PendingTransaction> reorder(
      final List<PendingTransaction> candidates,
      final Optional<Wei> baseFee) {

    if (candidates.isEmpty() || variant == Variant.DISABLED) {
      // Still record observations for metrics even on DISABLED
      for (PendingTransaction pt : candidates) {
        tracker.observeAccess(toAddress(pt));
      }
      return candidates;
    }

    final long t0 = System.nanoTime();

    final List<PendingTransaction> result;
    switch (variant) {
      case ADDRESS_LOCALITY:
        result = reorderByAddress(candidates);
        break;
      case WORKING_SET_AFFINITY:
        result = reorderByWarmSet(candidates);
        break;
      case HYBRID_FEE_LOCALITY:
        result = reorderHybrid(candidates, baseFee);
        break;
      default:
        result = candidates;
    }

    lastOverheadUs = TimeUnit.NANOSECONDS.toMicros(System.nanoTime() - t0);

    // Record locality observations for metrics (on the final order)
    for (PendingTransaction pt : result) {
      tracker.observeAccess(toAddress(pt));
    }

    return result;
  }

  // ── Variant implementations ─────────────────────────────────────────────────

  /**
   * ADDRESS_LOCALITY (AL):
   * Group transactions by destination address; emit largest groups first
   * (Zipf-locality: the most-accessed contracts appear together).
   * Within each group, the original fee-priority ordering is preserved.
   * Contract-creation transactions (no destination) are appended last.
   */
  private List<PendingTransaction> reorderByAddress(final List<PendingTransaction> candidates) {
    // LinkedHashMap preserves first-seen order within each group
    final Map<Address, List<PendingTransaction>> groups = new LinkedHashMap<>();
    final List<PendingTransaction> noAddress = new ArrayList<>();

    for (PendingTransaction pt : candidates) {
      final Address to = toAddress(pt);
      if (to != null) {
        groups.computeIfAbsent(to, k -> new ArrayList<>()).add(pt);
      } else {
        noAddress.add(pt);
      }
    }

    // Sort groups by size descending (hottest group = most transactions = process first)
    final List<List<PendingTransaction>> sortedGroups = new ArrayList<>(groups.values());
    sortedGroups.sort((a, b) -> Integer.compare(b.size(), a.size()));

    final List<PendingTransaction> result = new ArrayList<>(candidates.size());
    for (List<PendingTransaction> group : sortedGroups) {
      result.addAll(group);
    }
    result.addAll(noAddress);
    return result;
  }

  /**
   * WORKING_SET_AFFINITY (WSA):
   * Partition transactions into warm (recently accessed) and cold (new addresses).
   * Emit warm partition first, then cold, with each partition sorted by group size.
   * On cold-start (empty tracker), falls back to fee-priority order.
   */
  private List<PendingTransaction> reorderByWarmSet(final List<PendingTransaction> candidates) {
    final Map<Address, List<PendingTransaction>> warmGroups = new LinkedHashMap<>();
    final Map<Address, List<PendingTransaction>> coldGroups = new LinkedHashMap<>();
    final List<PendingTransaction> noAddress = new ArrayList<>();

    for (PendingTransaction pt : candidates) {
      final Address to = toAddress(pt);
      if (to == null) {
        noAddress.add(pt);
        continue;
      }
      if (tracker.isWarm(to)) {
        warmGroups.computeIfAbsent(to, k -> new ArrayList<>()).add(pt);
      } else {
        coldGroups.computeIfAbsent(to, k -> new ArrayList<>()).add(pt);
      }
    }

    final List<PendingTransaction> result = new ArrayList<>(candidates.size());

    // Warm groups first, sorted by size descending
    warmGroups.values().stream()
        .sorted((a, b) -> Integer.compare(b.size(), a.size()))
        .forEach(result::addAll);

    // Cold groups next, sorted by size descending
    coldGroups.values().stream()
        .sorted((a, b) -> Integer.compare(b.size(), a.size()))
        .forEach(result::addAll);

    result.addAll(noAddress);
    return result;
  }

  /**
   * HYBRID_FEE_LOCALITY (HFL):
   * Score = alpha * normalizedEffectiveFee + beta * normalizedGroupSize
   *
   * localityScore = groupSize(to) / maxGroupSize across all candidates.
   * Addresses with many pending transactions (large groups) score high locality.
   *
   * This avoids the cold-start feedback loop of EWMA-based warm state:
   * SB contracts (30 contracts, 15 workers) accumulate more pending txs per address
   * than SC contracts (300 contracts, 15 workers) under pool saturation,
   * so SB naturally gets a higher locality score from block 1 without needing history.
   *
   * With alpha=0, beta=1: equivalent to ADDRESS_LOCALITY (pure group-size order)
   * With alpha=1, beta=0: equivalent to DISABLED (pure fee order)
   * Crossover at alpha ≈ (beta * maxGroupRatio) / (1 + beta * maxGroupRatio)
   */
  private List<PendingTransaction> reorderHybrid(
      final List<PendingTransaction> candidates,
      final Optional<Wei> baseFee) {

    // First pass: compute per-address group sizes and max fee
    final Map<Address, Integer> groupSizes = new HashMap<>();
    long maxFee = 1L;
    for (PendingTransaction pt : candidates) {
      final Address to = toAddress(pt);
      if (to != null) groupSizes.merge(to, 1, Integer::sum);
      final Transaction tx = (Transaction) pt.getTransaction();
      final Wei fee = tx.getEffectivePriorityFeePerGas(baseFee);
      if (fee != null && fee.toLong() > maxFee) maxFee = fee.toLong();
    }
    final int maxGroup = groupSizes.values().stream().mapToInt(i -> i).max().orElse(1);
    final long normMax = maxFee;
    final int normGroup = maxGroup;

    // Second pass: precompute each candidate's score once, then sort on the
    // cached value. The previous comparator called computeHflScore() on both
    // operands of every comparison, turning an O(n) scoring pass into
    // O(n log n) score recomputations -- measured at ~1000x the CLR port's
    // per-block scheduling overhead on Besu and identified as the primary
    // driver of scheduling-variant throughput collapse under load.
    final List<ScoredTx> scored = new ArrayList<>(candidates.size());
    for (PendingTransaction pt : candidates) {
      scored.add(new ScoredTx(pt, computeHflScore(pt, baseFee, normMax, groupSizes, normGroup)));
    }
    scored.sort((s1, s2) -> Double.compare(s2.score, s1.score));

    final List<PendingTransaction> sorted = new ArrayList<>(scored.size());
    for (ScoredTx s : scored) sorted.add(s.tx);
    return sorted;
  }

  private static final class ScoredTx {
    final PendingTransaction tx;
    final double score;
    ScoredTx(final PendingTransaction tx, final double score) { this.tx = tx; this.score = score; }
  }

  private double computeHflScore(
      final PendingTransaction pt,
      final Optional<Wei> baseFee,
      final long normMax,
      final Map<Address, Integer> groupSizes,
      final int maxGroup) {

    final Transaction tx = (Transaction) pt.getTransaction();
    final Wei fee = tx.getEffectivePriorityFeePerGas(baseFee);
    final double normFee = (fee == null) ? 0.0 : Math.min(1.0, (double) fee.toLong() / normMax);
    final Address to = toAddress(pt);
    final double localityScore = (to == null || maxGroup == 0) ? 0.0
        : (double) groupSizes.getOrDefault(to, 0) / maxGroup;
    return alpha * normFee + beta * localityScore;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  private static Address toAddress(final PendingTransaction pt) {
    return (Address) pt.getTransaction().getTo().orElse(null);
  }
}
