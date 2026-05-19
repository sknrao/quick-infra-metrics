#!/bin/bash
# cpu_monitor.sh — bracket a testpmd run with per-CPU mpstat sampling
#
# Run on BOTH host and VM (same script, auto-detects context).
#
# Usage:
#   Start (before experiment):  sudo bash cpu_monitor.sh start [label]
#   Stop  (after experiment):   sudo bash cpu_monitor.sh stop
#
#   label is optional — use "host" or "vm" to distinguish the two log files.
#   Example:
#     On host:  sudo bash cpu_monitor.sh start host
#     In VM:    sudo bash cpu_monitor.sh start vm
#
# Output file: /tmp/cpu_monitor_<label>_<timestamp>.log
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

# Detect whether we are on the host or inside the VM.
# Mirrors the same heuristic used in net_hugepage_monitor.sh:
#   presence of ovs-vsctl (usable) OR /sys/class/vhost-net  →  host
#   otherwise                                                →  vm
detect_context() {
    if command -v ovs-vsctl >/dev/null 2>&1 && ovs-vsctl show >/dev/null 2>&1; then
        echo "host"
    elif [ -d /sys/class/vhost-net ]; then
        echo "host"
    else
        echo "vm"
    fi
}

# ── affinity snapshot — context-aware ────────────────────────────────────────
#
# In VM  : testpmd runs locally → grab taskset cpuset per PID directly.
# On host: testpmd is inside the CVM and is invisible here.
#           Instead, capture the QEMU vCPU thread → pCPU affinity, which is
#           the host-side equivalent: it shows which physical cores are
#           serving the VM's vCPUs.

snapshot_affinity() {
    local when="$1"          # "start" or "stop"
    local context="$2"       # "host" or "vm"

    echo "=== CPU affinity snapshot at ${when} (context: ${context}) ===" >> "$OUTFILE"

    if [ "$context" = "vm" ]; then
        # ── VM context: look for testpmd locally ──────────────────────────
        local found=0
        for pid in $(pgrep -f "dpdk-testpmd" 2>/dev/null); do
            local cpuset
            cpuset=$(taskset -cp "$pid" 2>/dev/null | awk -F': ' '{print $2}')
            echo "  testpmd PID $pid: cpuset=${cpuset}" >> "$OUTFILE"
            found=1
        done
        if [ "$found" -eq 0 ]; then
            echo "  (no dpdk-testpmd process found locally at ${when})" >> "$OUTFILE"
        fi

    else
        # ── Host context: testpmd lives inside the VM, not visible here ───
        echo "  Note: dpdk-testpmd runs inside the CVM — not visible on host." >> "$OUTFILE"
        echo "  Capturing QEMU vCPU-thread → physical-CPU affinity instead." >> "$OUTFILE"
        echo "" >> "$OUTFILE"

        local qemu_pid
        qemu_pid=$(pgrep -f "qemu-system" 2>/dev/null | head -1)

        if [ -z "$qemu_pid" ]; then
            echo "  (no qemu-system process found — cannot resolve vCPU affinity)" >> "$OUTFILE"
        else
            echo "  QEMU PID: $qemu_pid" >> "$OUTFILE"

            # Iterate over all QEMU threads; identify vCPU threads by name
            # (Linux names them "CPU 0/KVM", "CPU 1/KVM", etc.)
            local thread_found=0
            while IFS= read -r tid; do
                local tname pcpu cpuset
                tname=$(cat "/proc/${qemu_pid}/task/${tid}/comm" 2>/dev/null || echo "?")
                # Current pCPU the thread is scheduled on right now
                pcpu=$(awk '/^processor/{p=$3} /^voluntary/{print p}' \
                       /proc/${qemu_pid}/task/${tid}/status 2>/dev/null || echo "?")
                # Allowed cpuset (the pinning mask, if any)
                cpuset=$(taskset -cp "$tid" 2>/dev/null | awk -F': ' '{print $2}')
                printf "  TID %-7s  %-20s  allowed-cpuset=%-15s\n" \
                    "$tid" "$tname" "$cpuset" >> "$OUTFILE"
                thread_found=1
            done < <(ls /proc/${qemu_pid}/task/ 2>/dev/null)

            if [ "$thread_found" -eq 0 ]; then
                echo "  (could not enumerate QEMU threads)" >> "$OUTFILE"
            fi
        fi
    fi

    echo "" >> "$OUTFILE"
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

    CONTEXT="${1:-$(detect_context)}"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    OUTFILE="/tmp/cpu_monitor_${CONTEXT}_${TIMESTAMP}.log"

    echo "=== CPU monitor started at $(date) ===" > "$OUTFILE"
    echo "=== Host: $(hostname) | Kernel: $(uname -r) | Context: ${CONTEXT} ===" >> "$OUTFILE"

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

    # Affinity snapshot at start — context-aware
    snapshot_affinity "start" "$CONTEXT"

    echo "=== mpstat per-CPU samples (interval=${INTERVAL}s) ===" >> "$OUTFILE"

    # Run mpstat in background: all CPUs (-P ALL), 1-second intervals, unlimited samples
    mpstat -P ALL $INTERVAL >> "$OUTFILE" 2>&1 &
    MPSTAT_PID=$!

    echo "$MPSTAT_PID" > "$PIDFILE"
    echo "$OUTFILE"    > "$OUTFILE_TRACKER"
    echo "$CONTEXT"    > "/tmp/cpu_monitor.context"

    echo "✓ CPU monitor started (context: ${CONTEXT}, mpstat PID: $MPSTAT_PID)"
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
    CONTEXT=$(cat "/tmp/cpu_monitor.context" 2>/dev/null || detect_context)

    if ! kill -0 "$MPSTAT_PID" 2>/dev/null; then
        echo "WARNING: mpstat process $MPSTAT_PID no longer running."
    else
        kill "$MPSTAT_PID"
        wait "$MPSTAT_PID" 2>/dev/null
    fi

    echo "" >> "$OUTFILE"

    # Affinity snapshot at stop — context-aware
    snapshot_affinity "stop" "$CONTEXT"

    echo "=== CPU monitor stopped at $(date) ===" >> "$OUTFILE"

    rm -f "$PIDFILE" "$OUTFILE_TRACKER" "/tmp/cpu_monitor.context"

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
    start) do_start "${2:-}" ;;
    stop)  do_stop  ;;
    *)
        echo "Usage: sudo bash cpu_monitor.sh {start|stop} [label]"
        echo ""
        echo "  label: 'host' or 'vm' (auto-detected if omitted)"
        echo ""
        echo "  On host:  sudo bash cpu_monitor.sh start host"
        echo "  In VM:    sudo bash cpu_monitor.sh start vm"
        echo "  Stop:     sudo bash cpu_monitor.sh stop"
        exit 1
        ;;
esac
