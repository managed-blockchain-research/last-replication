#!/bin/bash

# Stop Besu gracefully and ensure logs are flushed

set -e

echo "Stopping Besu..."

if [ -f /tmp/besu_baseline.pid ]; then
    PID=$(cat /tmp/besu_baseline.pid)
    if kill -0 ${PID} 2>/dev/null; then
        echo "Sending SIGTERM to Besu (PID: ${PID})"
        kill ${PID}
        
        # Wait for graceful shutdown (up to 30 seconds)
        WAIT_COUNT=0
        while kill -0 ${PID} 2>/dev/null && [ ${WAIT_COUNT} -lt 30 ]; do
            echo -n "."
            sleep 1
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done
        echo ""
        
        # Force kill if still running
        if kill -0 ${PID} 2>/dev/null; then
            echo "WARNING: Besu did not stop gracefully, forcing shutdown..."
            kill -9 ${PID}
            sleep 2
        fi
        
        echo "✓ Besu stopped"
    else
        echo "Besu process (PID: ${PID}) is not running"
    fi
    rm -f /tmp/besu_baseline.pid
else
    # Try to find and kill by process name
    if pgrep -f "besu.*--network=dev" > /dev/null; then
        echo "Found Besu by process name, stopping..."
        pkill -TERM -f "besu.*--network=dev"
        sleep 3
        # Force kill if still running
        if pgrep -f "besu.*--network=dev" > /dev/null; then
            pkill -9 -f "besu.*--network=dev"
        fi
        echo "✓ Besu stopped"
    else
        echo "Besu is not running"
    fi
fi

echo "Done"
