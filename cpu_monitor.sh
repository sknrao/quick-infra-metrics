#!/bin/bash
# cpu_monitor.sh — bracket a testpmd run with per-CPU mpstat sampling
#
# Usage:
#   Start (before experiment):  sudo bash cpu_monitor.sh start
#   Stop  (after experiment):   sudo bash cpu_monitor.sh stop
#
# Output file: /tmp/cpu_monitor_<timestamp>.log
# The stop command prints the output path so you can feed it to analyze_cpu.py
#
# Dependencies: sysstat (mpstat)   Install: apt install sysstat
#               numactl (optional) Install: apt install numactl

PIDFILE="/tmp/cpu_monitor.pid"
OUTFILE_TRACKER="/tmp/cpu_monitor.outfile"
INTERVAL=1        # seconds between samples — 1s gives full resolution

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found. Install: apt install $2"
}

# ── start ────────────────────────────────────────────────────────────────────

do_start() {
    require_cmd mpstat sysstat

    if [ -f "$PIDFILE" ]; then
        OLD_PID=$(cat "$PIDFILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            die "Monitor already running (PID $OLD_PID). Stop it first."
        fi
        rm -f "$PIDFILE" "$OUTFILE_TRACKER"
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    OUTFILE="/tmp/cpu_monitor_${TIMESTAMP}.log"

    echo "=== CPU monitor started at $(date) ===" > "$OUTFILE"
    echo "=== Host: $(hostname) | Kernel: $(uname -r) ===" >> "$OUTFILE"

    # Log CPU topology so the analyzer can map vCPU→socket/core
    echo "=== CPU topology ===" >> "$OUTFILE"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu >> "$OUTFILE"
    fi
    echo "" >> "$OUTFILE"

    # Log NUMA layout if numactl available
    if command -v numactl >/dev/null 2>&1; then
        echo "=== NUMA layout ===" >> "$OUTFILE"
        numactl --hardware >> "$OUTFILE"
        echo "" >> "$OUTFILE"
    fi

    # Log initial cgroups/cpuset for testpmd if already running
    # (usually it isn't yet — this is a pre-run snapshot)
    echo "=== CPU affinity snapshot at start ===" >> "$OUTFILE"
    for pid in $(pgrep -f "dpdk-testpmd" 2>/dev/null); do
        echo "  testpmd PID $pid: cpuset=$(taskset -cp $pid 2>/dev/null | awk -F': ' '{print $2}')" >> "$OUTFILE"
    done
    echo "" >> "$OUTFILE"

    echo "=== mpstat per-CPU samples (interval=${INTERVAL}s) ===" >> "$OUTFILE"

    # Run mpstat in background: all CPUs (-P ALL), 1-second intervals, unlimited samples
    # -o JSON would be nicer but some older sysstat versions don't support it
    mpstat -P ALL $INTERVAL >> "$OUTFILE" 2>&1 &
    MPSTAT_PID=$!

    echo "$MPSTAT_PID" > "$PIDFILE"
    echo "$OUTFILE"    > "$OUTFILE_TRACKER"

    echo "✓ CPU monitor started (mpstat PID: $MPSTAT_PID)"
    echo "  Sampling every ${INTERVAL}s → $OUTFILE"
    echo ""
    echo "  Now start your experiment. When done, run:"
    echo "    sudo bash cpu_monitor.sh stop"
}

# ── stop ─────────────────────────────────────────────────────────────────────

do_stop() {
    if [ ! -f "$PIDFILE" ]; then
        die "No running monitor found (no $PIDFILE). Did you run 'start'?"
    fi

    MPSTAT_PID=$(cat "$PIDFILE")
    OUTFILE=$(cat "$OUTFILE_TRACKER" 2>/dev/null || echo "unknown")

    if ! kill -0 "$MPSTAT_PID" 2>/dev/null; then
        echo "WARNING: mpstat process $MPSTAT_PID no longer running."
    else
        kill "$MPSTAT_PID"
        wait "$MPSTAT_PID" 2>/dev/null
    fi

    echo "" >> "$OUTFILE"
    echo "=== CPU affinity snapshot at stop ===" >> "$OUTFILE"
    for pid in $(pgrep -f "dpdk-testpmd" 2>/dev/null); do
        echo "  testpmd PID $pid: cpuset=$(taskset -cp $pid 2>/dev/null | awk -F': ' '{print $2}')" >> "$OUTFILE"
    done
    echo "=== CPU monitor stopped at $(date) ===" >> "$OUTFILE"

    rm -f "$PIDFILE" "$OUTFILE_TRACKER"

    echo "✓ CPU monitor stopped."
    echo ""
    echo "  Output file: $OUTFILE"
    echo ""
    echo "  To analyze:"
    echo "    python3 analyze_cpu.py $OUTFILE"
    echo ""
    echo "  To get a quick per-CPU summary right now:"
    echo "    grep 'Average' $OUTFILE | grep -v '^Average.*CPU' | sort -k3 -rn"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
    start) do_start ;;
    stop)  do_stop  ;;
    *)
        echo "Usage: sudo bash cpu_monitor.sh {start|stop}"
        echo ""
        echo "  start  — begin per-CPU mpstat sampling (run before experiment)"
        echo "  stop   — stop sampling and print the output file path"
        exit 1
        ;;
esac
