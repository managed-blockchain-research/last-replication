#!/usr/bin/env bash
set -euo pipefail

PID_FILE="/tmp/nethermind_spaceneth.pid"

stop_pid() {
  pid="$1"
  if [[ -z "${pid}" ]]; then
    return 0
  fi
  if [[ -d "/proc/${pid}" ]]; then
    echo "Stopping Nethermind (PID ${pid})..."
    kill "${pid}" || true
    sleep 3
    if [[ -d "/proc/${pid}" ]]; then
      echo "PID ${pid} still running; sending SIGKILL..."
      kill -9 "${pid}" || true
      sleep 2
    fi
  fi
}

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}" | tr -d '[:space:]' || true)"
  stop_pid "${pid}"
  rm -f "${PID_FILE}" || true
else
  # Best-effort fallback if pid file is missing
  pid="$(pgrep -f "nethermind.dll.*spaceneth" | head -n 1 || true)"
  stop_pid "${pid}"
fi

echo "Nethermind spaceneth stopped."

