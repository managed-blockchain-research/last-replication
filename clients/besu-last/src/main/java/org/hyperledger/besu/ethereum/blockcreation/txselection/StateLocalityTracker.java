/*
 * LAST: Locality-Aware Scheduling of Transactions
 * StateLocalityTracker — EWMA-based warm-set tracking across block boundaries.
 *
 * Tracks which contract addresses were recently touched by executed transactions.
 * Uses exponential-weighted moving average (EWMA) decay so that addresses that
 * are not accessed slowly cool off, while frequently-touched ones remain warm.
 *
 * Thread safety: single-threaded within Besu's block creation FutureTask.
 */
package org.hyperledger.besu.ethereum.blockcreation.txselection;

import org.hyperledger.besu.datatypes.Address;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

public class StateLocalityTracker {

  /** EWMA decay factor applied on each transaction boundary within a block. */
  private static final double DECAY_PER_TX = 0.98;

  /** EWMA decay factor applied between blocks (heavier cooldown). */
  private static final double DECAY_PER_BLOCK = 0.80;

  /** Minimum score to be considered "warm". Entries below this are evicted. */
  private static final double WARM_THRESHOLD = 0.05;

  /** Score added for each access hit. */
  private static final double ACCESS_DELTA = 1.0;

  private final Map<Address, Double> scores = new HashMap<>();

  // Per-block accounting (reset each block)
  private long warmHits = 0;
  private long coldMisses = 0;

  // ── Public API ──────────────────────────────────────────────────────────────

  /**
   * Record that a set of addresses was accessed during a transaction.
   * Increments the EWMA score for each address.
   */
  public void recordAccess(final Set<Address> addresses) {
    for (Address addr : addresses) {
      scores.merge(addr, ACCESS_DELTA, Double::sum);
    }
  }

  /**
   * Apply per-transaction EWMA decay and update warm/cold hit counters.
   * Must be called after each executed transaction.
   */
  public void onTransactionBoundary() {
    scores.replaceAll((addr, score) -> score * DECAY_PER_TX);
    scores.entrySet().removeIf(e -> e.getValue() < WARM_THRESHOLD);
  }

  /**
   * Light reset between blocks: apply a single block-level decay round.
   * Does NOT clear the warm-set — inter-block warm state is intentional.
   */
  public void reset() {
    scores.replaceAll((addr, score) -> score * DECAY_PER_BLOCK);
    scores.entrySet().removeIf(e -> e.getValue() < WARM_THRESHOLD);
    warmHits = 0;
    coldMisses = 0;
  }

  /**
   * Returns true if the given address is currently warm.
   * Null-safe: returns false for null.
   */
  public boolean isWarm(final Address addr) {
    if (addr == null) return false;
    return scores.getOrDefault(addr, 0.0) >= WARM_THRESHOLD;
  }

  /**
   * Returns the continuous locality score for the given address, normalized to [0, 1].
   * Cold (never accessed) addresses return 0.0; recently accessed addresses approach 1.0.
   * Null-safe: returns 0.0 for null.
   */
  public double getScore(final Address addr) {
    if (addr == null) return 0.0;
    double raw = scores.getOrDefault(addr, 0.0);
    // Normalize: raw score ~1.0 for singly-accessed, higher for hot addresses.
    // tanh maps (0,∞) → (0,1) smoothly without a hard cap.
    return Math.tanh(raw);
  }

  /**
   * Record a locality observation for metrics.
   * Call this before scheduling each transaction.
   */
  public void observeAccess(final Address addr) {
    if (addr == null) return;
    if (isWarm(addr)) {
      warmHits++;
    } else {
      coldMisses++;
    }
  }

  /** Number of warm entries currently tracked. */
  public int getWarmSetSize() {
    return scores.size();
  }

  /** Warm-hit count since last reset(). */
  public long getWarmHits() {
    return warmHits;
  }

  /** Cold-miss count since last reset(). */
  public long getColdMisses() {
    return coldMisses;
  }

  /** Total observations since last reset(). */
  public long getTotalObservations() {
    return warmHits + coldMisses;
  }

  /** Warm-hit rate since last reset(), in [0,1]. Returns 0.0 if no observations. */
  public double getWarmHitRate() {
    long total = warmHits + coldMisses;
    return total == 0 ? 0.0 : (double) warmHits / total;
  }
}
