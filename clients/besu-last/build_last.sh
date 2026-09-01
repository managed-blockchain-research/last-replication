#!/usr/bin/env bash
# build_last.sh — Compile LAST sources and inject patched JAR into besu-source distribution.
#
# Usage: bash build_last.sh
#
# What it does:
#   1. Compiles 4 Java files (StateLocalityTracker, LASTScheduler, LASTMetricsLogger,
#      patched BlockTransactionSelector) against the besu-source v24.1.1 library JARs.
#   2. Extracts besu-blockcreation-24.1.1.jar, overlays the new class files, repacks.
#   3. Backs up the original JAR as besu-blockcreation-24.1.1.jar.orig
#      (idempotent: skip if backup already exists).
#
# After running, the besu-source binary is the "LAST-patched" Besu.
# Pass -Dlast.variant=ADDRESS_LOCALITY etc. via BESU_OPTS when starting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCDIR="$SCRIPT_DIR/src/main/java"
OUTDIR="$SCRIPT_DIR/build/classes"

BESU_HOME=/home/yeochan.yoon/besu-source/build/install/besu
BESU_LIB="$BESU_HOME/lib"
ORIGINAL_JAR="$BESU_LIB/besu-blockcreation-24.1.1.jar"
BACKUP_JAR="$BESU_LIB/besu-blockcreation-24.1.1.jar.orig"
PATCHED_JAR="$BESU_LIB/besu-blockcreation-last-24.1.1.jar"

JAVA_HOME_17=/usr/lib/jvm/java-17-openjdk-17.0.13.0.11-3.el8.x86_64
JAVAC="$JAVA_HOME_17/bin/javac"

TXSEL_PKG="org/hyperledger/besu/ethereum/blockcreation/txselection"
SOURCES=(
  "$SRCDIR/$TXSEL_PKG/StateLocalityTracker.java"
  "$SRCDIR/$TXSEL_PKG/LASTScheduler.java"
  "$SRCDIR/$TXSEL_PKG/LASTMetricsLogger.java"
  "$SRCDIR/$TXSEL_PKG/BlockTransactionSelector.java"
)

# ── Step 1: Compile ─────────────────────────────────────────────────────────
echo "[LAST] Compiling LAST sources with Java 17..."
mkdir -p "$OUTDIR"
"$JAVAC" -proc:none \
  -source 17 -target 17 \
  -cp "$BESU_LIB/*" \
  -d "$OUTDIR" \
  "${SOURCES[@]}"
echo "[LAST] Compilation OK"

# ── Step 2: Backup original JAR (idempotent) ────────────────────────────────
if [ ! -f "$BACKUP_JAR" ]; then
  echo "[LAST] Backing up original JAR → $(basename "$BACKUP_JAR")"
  cp "$ORIGINAL_JAR" "$BACKUP_JAR"
else
  echo "[LAST] Backup already exists at $(basename "$BACKUP_JAR"), skipping"
fi

# ── Step 3: Extract original JAR and overlay LAST classes ───────────────────
WORK_DIR="$(mktemp -d)"
trap "rm -rf '$WORK_DIR'" EXIT

echo "[LAST] Extracting original JAR..."
cp "$BACKUP_JAR" "$WORK_DIR/original.jar"
pushd "$WORK_DIR" > /dev/null
jar xf original.jar
popd > /dev/null

echo "[LAST] Overlaying LAST class files..."
cp -r "$OUTDIR/org" "$WORK_DIR/"

echo "[LAST] Repacking JAR → $(basename "$ORIGINAL_JAR")"
pushd "$WORK_DIR" > /dev/null
jar cf "$ORIGINAL_JAR" .
popd > /dev/null

echo "[LAST] Patched JAR written to: $ORIGINAL_JAR"
echo ""
echo "Besu (LAST-patched) is ready. Start with:"
echo "  export BESU_OPTS=\"\$BESU_OPTS -Dlast.variant=ADDRESS_LOCALITY -Dlast.log.path=/tmp/last_metrics.csv\""
echo "  /home/yeochan.yoon/besu-source/build/install/besu/bin/besu --network=dev --miner-enabled ..."
echo ""
echo "To restore the original JAR:"
echo "  cp $BACKUP_JAR $ORIGINAL_JAR"
