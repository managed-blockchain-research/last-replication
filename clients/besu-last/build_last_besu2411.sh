#!/usr/bin/env bash
# build_last_besu2411.sh — Patch besu-24.1.1 (vanilla, no LASS) with LAST classes.
#
# Purpose: creates a LAST-only binary for the joint LAST+LASS experiment.
#   besu-source  = LASS + LAST  (LASS unconditional, LAST via -Dlast.variant)
#   besu-24.1.1  = vanilla      (no LASS, no LAST)
# After this script:
#   besu-24.1.1  = LAST-only    (LAST via -Dlast.variant, still no LASS)
#
# To restore vanilla: cp besu-blockcreation-24.1.1.jar.orig besu-blockcreation-24.1.1.jar
#
# Usage: bash build_last_besu2411.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCDIR="$SCRIPT_DIR/src/main/java"
OUTDIR="$SCRIPT_DIR/build/classes"

BESU_HOME=/home/yeochan.yoon/besu-24.1.1
BESU_LIB="$BESU_HOME/lib"
ORIGINAL_JAR="$BESU_LIB/besu-blockcreation-24.1.1.jar"
BACKUP_JAR="$BESU_LIB/besu-blockcreation-24.1.1.jar.orig"

JAVA_HOME_17="${JAVA_HOME_17:-/home/yeochan.yoon/jdk17-portable}"
JAVAC="$JAVA_HOME_17/bin/javac"

TXSEL_PKG="org/hyperledger/besu/ethereum/blockcreation/txselection"
SOURCES=(
  "$SRCDIR/$TXSEL_PKG/StateLocalityTracker.java"
  "$SRCDIR/$TXSEL_PKG/LASTScheduler.java"
  "$SRCDIR/$TXSEL_PKG/LASTMetricsLogger.java"
  "$SRCDIR/$TXSEL_PKG/BlockTransactionSelector.java"
)

# ── Step 1: Compile ─────────────────────────────────────────────────────────
echo "[LAST-2411] Compiling LAST sources against besu-24.1.1 libraries..."
mkdir -p "$OUTDIR"
"$JAVAC" -proc:none \
  -source 17 -target 17 \
  -cp "$BESU_LIB/*" \
  -d "$OUTDIR" \
  "${SOURCES[@]}"
echo "[LAST-2411] Compilation OK"

# ── Step 2: Backup original JAR (idempotent) ────────────────────────────────
if [ ! -f "$BACKUP_JAR" ]; then
  echo "[LAST-2411] Backing up original JAR → $(basename "$BACKUP_JAR")"
  cp "$ORIGINAL_JAR" "$BACKUP_JAR"
else
  echo "[LAST-2411] Backup already exists, skipping"
fi

# ── Step 3: Overlay LAST classes into a fresh copy of the original JAR ──────
WORK_DIR="$(mktemp -d)"
trap "rm -rf '$WORK_DIR'" EXIT

echo "[LAST-2411] Extracting original JAR..."
cp "$BACKUP_JAR" "$WORK_DIR/original.jar"
pushd "$WORK_DIR" > /dev/null
jar xf original.jar
popd > /dev/null

echo "[LAST-2411] Overlaying LAST class files..."
cp -r "$OUTDIR/org" "$WORK_DIR/"

echo "[LAST-2411] Repacking JAR → $(basename "$ORIGINAL_JAR")"
pushd "$WORK_DIR" > /dev/null
jar cf "$ORIGINAL_JAR" .
popd > /dev/null

echo ""
echo "[LAST-2411] Done. besu-24.1.1 now has LAST (no LASS)."
echo "Binary: $BESU_HOME/bin/besu"
echo "Control via: export BESU_OPTS=\"-Dlast.variant=WORKING_SET_AFFINITY -Dlast.log.path=/tmp/last.csv\""
echo ""
echo "To restore vanilla besu-24.1.1:"
echo "  cp $BACKUP_JAR $ORIGINAL_JAR"
