#!/bin/bash
# net_hugepage_monitor.sh — track interface counters + hugepage usage
#
# Run on BOTH host and VM (same script, auto-detects context).
# Brackets a single experiment run: start before, stop after.
#
# Usage:
#   Start:  sudo bash net_hugepage_monitor.sh start [label]
#   Stop:   sudo bash net_hugepage_monitor.sh stop
#
#   label is optional — use "host" or "vm" to distinguish the two log files.
#   Example:
#     On host:  sudo bash net_hugepage_monitor.sh start host
#     In VM:    sudo bash net_hugepage_monitor.sh start vm
#
# Output: /tmp/net_hugepage_<label>_<timestamp>.log
#
# After stopping, run:
#   python3 analyze_net_hugepage.py /tmp/net_hugepage_host_*.log \
#                                   /tmp/net_hugepage_vm_*.log
#
# Dependencies: iproute2 (ip), ethtool, bash — all standard on Ubuntu.
#               ovs-vsctl needed on host for OVS port stats (optional).

PIDFILE="/tmp/net_hugepage_monitor.pid"
OUTFILE_TRACKER="/tmp/net_hugepage_monitor.outfile"
INTERVAL=2        # seconds between samples — 2s is fine; counters are cumulative

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

# Detect whether we are on the host or inside the VM.
# Heuristic: presence of /sys/class/vhost-net or ovs-vsctl → host.
detect_context() {
    if command -v ovs-vsctl >/dev/null 2>&1 && ovs-vsctl show >/dev/null 2>&1; then
        echo "host"
    elif [ -d /sys/class/vhost-net ]; then
        echo "host"
    else
        echo "vm"
    fi
}

# Return all network interfaces worth watching (exclude lo and virtual noise).
get_interfaces() {
    ip -br link show | awk '{print $1}' | grep -Ev '^(lo|docker|virbr|veth|dummy)' | sed 's/@.*//'
}

# Snapshot one interface: ip -s link + ethtool -S (if available)
snapshot_iface() {
    local iface="$1"
    echo "  --- $iface ---"
    ip -s link show "$iface" 2>/dev/null | tail -n +2  # skip the first line (redundant with header)
    # ethtool extended stats — skip silently if iface doesn't support it
    local xstats
    xstats=$(ethtool -S "$iface" 2>/dev/null | grep -v ': 0' | grep -v 'NIC statistics')
    if [ -n "$xstats" ]; then
        echo "  ethtool -S $iface (non-zero):"
        echo "$xstats" | sed 's/^/    /'
    fi
}

# Snapshot OVS port stats (host only, silent if not available)
snapshot_ovs() {
    command -v ovs-vsctl >/dev/null 2>&1 || return
    ovs-vsctl show >/dev/null 2>&1      || return
    echo "  --- OVS bridge/port stats ---"
    # Per-port stats: ovs-ofctl dump-ports for each bridge
    for br in $(ovs-vsctl list-br 2>/dev/null); do
        echo "  bridge: $br"
        ovs-ofctl dump-ports "$br" 2>/dev/null | sed 's/^/    /'
    done
}

# Snapshot hugepage usage from /proc/meminfo and per-NUMA sysfs
snapshot_hugepages() {
    echo "  --- /proc/meminfo hugepages ---"
    grep -i huge /proc/meminfo | sed 's/^/    /'

    echo "  --- per-NUMA hugepages (/sys) ---"
    for node_dir in /sys/devices/system/node/node*/hugepages; do
        node=$(basename "$(dirname "$node_dir")")
        for size_dir in "$node_dir"/hugepages-*; do
            size=$(basename "$size_dir")
            total=$(cat "$size_dir/nr_hugepages"    2>/dev/null || echo "?")
            free=$(cat  "$size_dir/free_hugepages"  2>/dev/null || echo "?")
            rsvd=$(cat  "$size_dir/resv_hugepages"  2>/dev/null || echo "?")
            surp=$(cat  "$size_dir/surplus_hugepages" 2>/dev/null || echo "?")
            echo "    $node  $size  total=$total  free=$free  rsvd=$rsvd  surp=$surp"
        done
    done

    # Also show DPDK hugepage files if present
    echo "  --- DPDK hugepage files (/dev/hugepages) ---"
    if [ -d /dev/hugepages ]; then
        ls -lh /dev/hugepages/ 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
    else
        echo "    /dev/hugepages not mounted"
    fi

    # 1G hugetlbfs mount if present
    echo "  --- hugetlbfs mounts ---"
    mount | grep hugetlbfs | sed 's/^/    /' || echo "    none"
}

# ── one full snapshot pass ────────────────────────────────────────────────────

do_snapshot() {
    local tag="${1:-SAMPLE}"   # "BASELINE" for T=0, "SAMPLE" for polling samples
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo ""
    echo "════ ${tag}  $ts ════"

    echo "=IFACES="
    for iface in $(get_interfaces); do
        snapshot_iface "$iface"
    done
    snapshot_ovs

    echo "=HUGEPAGES="
    snapshot_hugepages
}

# ── start ─────────────────────────────────────────────────────────────────────

do_start() {
    if [ -f "$PIDFILE" ]; then
        OLD_PID=$(cat "$PIDFILE")
        kill -0 "$OLD_PID" 2>/dev/null && die "Monitor already running (PID $OLD_PID). Stop it first."
        rm -f "$PIDFILE" "$OUTFILE_TRACKER"
    fi

    LABEL="${1:-$(detect_context)}"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    OUTFILE="/tmp/net_hugepage_${LABEL}_${TIMESTAMP}.log"

    {
        echo "=== net+hugepage monitor ==="
        echo "=== label=$LABEL  host=$(hostname)  kernel=$(uname -r) ==="
        echo "=== started=$(date) ==="
        echo "=== interval=${INTERVAL}s ==="
        echo ""

        # Static config snapshot once at start
        echo "====== STATIC CONFIG ======"
        echo "-- interfaces present --"
        ip -br link show | sed 's/^/  /'
        echo "-- ip route --"
        ip route show | sed 's/^/  /'
        echo "-- XDP programs attached --"
        for iface in $(get_interfaces); do
            xdp=$(ip link show "$iface" 2>/dev/null | grep "prog/xdp")
            [ -n "$xdp" ] && echo "  $iface: $xdp"
        done
        if command -v bpftool >/dev/null 2>&1; then
            echo "-- bpftool net list --"
            bpftool net list 2>/dev/null | sed 's/^/  /' || true
        fi
        echo ""

        # OVS static config (host)
        if command -v ovs-vsctl >/dev/null 2>&1 && ovs-vsctl show >/dev/null 2>&1; then
            echo "-- OVS topology --"
            ovs-vsctl show | sed 's/^/  /'
            echo "-- OVS DPDK port details --"
            ovs-vsctl list Interface | grep -E 'name|type|options|statistics' | sed 's/^/  /'
        fi
        echo "=============================="
        echo ""

        # T=0 baseline — captured synchronously the moment 'start' is called.
        # The analyzer subtracts these absolute counter values from every
        # subsequent sample, so pre-existing traffic is excluded from all rates
        # and totals. This is intentionally BASELINE-tagged, not SAMPLE-tagged.
        do_snapshot BASELINE

        # Polling loop — regular SAMPLE-tagged snapshots
        while true; do
            sleep "$INTERVAL"
            do_snapshot SAMPLE
        done
    } >> "$OUTFILE" 2>&1 &

    BG_PID=$!
    echo "$BG_PID" > "$PIDFILE"
    echo "$OUTFILE" > "$OUTFILE_TRACKER"

    echo "✓ Monitor started (PID: $BG_PID, label: $LABEL)"
    echo "  Output: $OUTFILE"
    echo ""
    echo "  Run the experiment now. When done:"
    echo "    sudo bash net_hugepage_monitor.sh stop"
}

# ── stop ──────────────────────────────────────────────────────────────────────

do_stop() {
    [ -f "$PIDFILE" ] || die "No running monitor ($PIDFILE not found). Did you run 'start'?"

    BG_PID=$(cat "$PIDFILE")
    OUTFILE=$(cat "$OUTFILE_TRACKER" 2>/dev/null || echo "unknown")

    if kill -0 "$BG_PID" 2>/dev/null; then
        # Kill the background subshell and all its children (the sleep, etc.)
        kill -- "-$BG_PID" 2>/dev/null || kill "$BG_PID" 2>/dev/null
        wait "$BG_PID" 2>/dev/null || true
    else
        echo "WARNING: process $BG_PID already gone."
    fi

    echo "=== monitor stopped $(date) ===" >> "$OUTFILE" 2>/dev/null || true
    rm -f "$PIDFILE" "$OUTFILE_TRACKER"

    echo "✓ Monitor stopped."
    echo "  Output: $OUTFILE"
    echo ""
    echo "  Analyze:"
    echo "    python3 analyze_net_hugepage.py $OUTFILE"
    echo "    python3 analyze_net_hugepage.py /tmp/net_hugepage_host_*.log /tmp/net_hugepage_vm_*.log"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
    start) do_start "${2:-}" ;;
    stop)  do_stop ;;
    *)
        echo "Usage: sudo bash net_hugepage_monitor.sh {start|stop} [label]"
        echo ""
        echo "  label: 'host' or 'vm' (auto-detected if omitted)"
        echo ""
        echo "  On host:  sudo bash net_hugepage_monitor.sh start host"
        echo "  In VM:    sudo bash net_hugepage_monitor.sh start vm"
        echo "  Stop:     sudo bash net_hugepage_monitor.sh stop"
        exit 1
        ;;
esac
