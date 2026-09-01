/*
 * LAST: Locality-Aware Scheduling of Transactions
 * LASTMetricsLogger — per-block CSV metrics logger.
 *
 * Writes one row per sealed block to a CSV file. Captures:
 *   - block number, variant, tx count, warm/cold hits
 *   - scheduler overhead, block construction time
 *   - per-block GC delta (count + time for Young and Old collectors)
 *
 * The GC delta approach (current_total - previous_total) gives per-block
 * attribution of GC activity, which is the key proxy metric for the paper.
 *
 * Thread safety: logBlock() is called from the block-creation thread only.
 */
package org.hyperledger.besu.ethereum.blockcreation.txselection;

import java.io.FileWriter;
import java.io.IOException;
import java.io.PrintWriter;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.time.Instant;
import java.util.List;

public class LASTMetricsLogger implements AutoCloseable {

  // CSV header
  private static final String HEADER =
      "timestamp_ms,block_number,last_variant,"
          + "tx_count,warm_hits,cold_misses,warm_set_size,warm_hit_rate,"
          + "scheduler_overhead_us,block_duration_ms,"
          + "gc_young_delta_count,gc_old_delta_count,"
          + "gc_young_delta_ms,gc_old_delta_ms,gc_total_delta_ms,gc_pause_ratio";

  private final PrintWriter writer;
  private final LASTScheduler scheduler;
  private final StateLocalityTracker tracker;
  private final List<GarbageCollectorMXBean> gcBeans;

  // Baseline GC counters (updated each call so we emit deltas)
  private long baseYoungCount = 0;
  private long baseOldCount   = 0;
  private long baseYoungMs    = 0;
  private long baseOldMs      = 0;

  public LASTMetricsLogger(
      final String logPath,
      final LASTScheduler scheduler,
      final StateLocalityTracker tracker) throws IOException {

    this.scheduler = scheduler;
    this.tracker   = tracker;
    this.gcBeans   = ManagementFactory.getGarbageCollectorMXBeans();

    // BlockTransactionSelector is instantiated per block, so we append to avoid
    // overwriting previous blocks' data. Write header only when file is new/empty.
    final java.io.File logFile = new java.io.File(logPath);
    final boolean needsHeader = !logFile.exists() || logFile.length() == 0;
    final FileWriter fw = new FileWriter(logPath, /* append= */ true);
    this.writer = new PrintWriter(fw, /* autoFlush= */ true);
    if (needsHeader) {
      writer.println(HEADER);
    }

    // Capture baseline so first block shows correct delta
    baseYoungCount = gcCount(false);
    baseOldCount   = gcCount(true);
    baseYoungMs    = gcTimeMs(false);
    baseOldMs      = gcTimeMs(true);
  }

  /**
   * Append one CSV row for the block that was just sealed.
   *
   * @param blockNumber       block height of the sealed block
   * @param txCount           number of transactions selected into the block
   * @param blockDurationMs   total block construction time in milliseconds
   */
  public void logBlock(
      final long blockNumber,
      final int txCount,
      final long blockDurationMs) {

    final long nowMs = Instant.now().toEpochMilli();

    // GC delta since last call
    final long curYoungCount = gcCount(false);
    final long curOldCount   = gcCount(true);
    final long curYoungMs    = gcTimeMs(false);
    final long curOldMs      = gcTimeMs(true);

    final long deltaYoungCount = Math.max(0, curYoungCount - baseYoungCount);
    final long deltaOldCount   = Math.max(0, curOldCount   - baseOldCount);
    final long deltaYoungMs    = Math.max(0, curYoungMs    - baseYoungMs);
    final long deltaOldMs      = Math.max(0, curOldMs      - baseOldMs);
    final long deltaTotalMs    = deltaYoungMs + deltaOldMs;

    baseYoungCount = curYoungCount;
    baseOldCount   = curOldCount;
    baseYoungMs    = curYoungMs;
    baseOldMs      = curOldMs;

    // Locality stats from tracker
    final long warmHits   = tracker.getWarmHits();
    final long coldMisses = tracker.getColdMisses();
    final int  warmSize   = tracker.getWarmSetSize();
    final double hitRate  = tracker.getWarmHitRate();

    // Scheduler overhead from last reorder() call
    final long overheadUs = scheduler.getLastOverheadUs();

    // Pause ratio: fraction of block time spent in GC
    final double pauseRatio = blockDurationMs > 0
        ? (double) deltaTotalMs / blockDurationMs
        : 0.0;

    writer.printf(
        "%d,%d,%s,%d,%d,%d,%d,%.4f,%d,%d,%d,%d,%d,%d,%d,%.4f%n",
        nowMs,
        blockNumber,
        scheduler.getVariant().name(),
        txCount,
        warmHits,
        coldMisses,
        warmSize,
        hitRate,
        overheadUs,
        blockDurationMs,
        deltaYoungCount,
        deltaOldCount,
        deltaYoungMs,
        deltaOldMs,
        deltaTotalMs,
        pauseRatio);
  }

  @Override
  public void close() {
    if (writer != null) {
      writer.flush();
      writer.close();
    }
  }

  // ── GC helpers ──────────────────────────────────────────────────────────────

  /**
   * Sum collection counts across all GC beans that match the old/young category.
   * Young collectors typically have names containing "G1 Young", "PS Scavenge", etc.
   * Old collectors contain "G1 Old", "PS MarkSweep", "ConcurrentMarkSweep", etc.
   */
  private long gcCount(final boolean old) {
    long total = 0;
    for (GarbageCollectorMXBean gc : gcBeans) {
      if (isOldGen(gc.getName()) == old) {
        long cnt = gc.getCollectionCount();
        if (cnt >= 0) total += cnt;
      }
    }
    return total;
  }

  private long gcTimeMs(final boolean old) {
    long total = 0;
    for (GarbageCollectorMXBean gc : gcBeans) {
      if (isOldGen(gc.getName()) == old) {
        long ms = gc.getCollectionTime();
        if (ms >= 0) total += ms;
      }
    }
    return total;
  }

  private static boolean isOldGen(final String name) {
    // G1GC names: "G1 Young Generation", "G1 Old Generation"
    // ParallelGC:  "PS Scavenge", "PS MarkSweep"
    // ZGC: "ZGC" (single collector, treat as old)
    final String lower = name.toLowerCase();
    return lower.contains("old") || lower.contains("marksweep")
        || lower.contains("concurrent") || lower.contains("zgc")
        || lower.contains("shenandoah");
  }
}
