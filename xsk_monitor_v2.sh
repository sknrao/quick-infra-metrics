#!/bin/bash
# xsk_monitor.sh — real-time AF_XDP socket health monitor
# Run INSIDE the VM while testpmd is running
#
# Usage: sudo bash xsk_monitor.sh [interval_seconds] [log_file]
#
#   interval_seconds : sampling interval (default: 1)
#   log_file         : optional path to save output (default: auto-named in /tmp)
#                      pass "-" to disable file logging
#
# Examples:
#   sudo bash xsk_monitor.sh              # 1s interval, auto log file
#   sudo bash xsk_monitor.sh 2            # 2s interval, auto log file
#   sudo bash xsk_monitor.sh 1 /tmp/x.log # explicit log file
#   sudo bash xsk_monitor.sh 1 -          # live only, no log file
#
# Columns:
#   xdp_pps     — packets/s arriving from NIC into XDP layer
#   drop_pps    — packets/s dropped after XDP redirect (fill ring starvation)
#   drop%       — drop rate this interval
#   fwd_pps     — packets/s successfully forwarded to testpmd (xdp_pps - drop_pps)
#   rx_kicks/s  — times kernel woke testpmd to signal new RX data
#   tx_kicks/s  — times testpmd kicked kernel for TX completions
#   status      — FILL_STARVE / KICK_STORM / STABLE / IDLE
#
# Also reads /proc/net/xdp for fill_ring_empty (most direct fill starvation counter)
# and /proc/<testpmd>/fdinfo for per-socket ring consumer/producer positions

INTERVAL=${1:-1}
LOG_ARG=${2:-""}           # explicit log file, "-" = no file, "" = auto
IFACES="enp0s3 enp0s4"

declare -A prev_xdp prev_drops prev_redir prev_rxk prev_txk

# ── Per-interface session accumulators (for exit summary) ──────────────────
declare -A acc_xdp acc_drp acc_fwd acc_rxk acc_txk acc_intervals
declare -A worst_drop_pct worst_drop_ts best_fwd_pps
for iface in $IFACES; do
    acc_xdp[$iface]=0; acc_drp[$iface]=0; acc_fwd[$iface]=0
    acc_rxk[$iface]=0; acc_txk[$iface]=0; acc_intervals[$iface]=0
    worst_drop_pct[$iface]=0; worst_drop_ts[$iface]="—"
    best_fwd_pps[$iface]=0
done
SESSION_START=$(date '+%Y-%m-%d %H:%M:%S')

header_every=20   # re-print header every N rows
row=0

print_summary() {
    # Disable the trap so we don't recurse if something errors in here
    trap - INT TERM EXIT
    local session_end
    session_end=$(date '+%Y-%m-%d %H:%M:%S')

    # Write summary to original stdout (fd 3) so it appears even if tee
    # has already closed, and also to the log via normal stdout.
    {
        printf "
"
        printf "══════════════════════════════════════════════════════════════════════
"
        printf "  XSK SESSION SUMMARY
"
        printf "══════════════════════════════════════════════════════════════════════
"
        printf "  Started  : %s
" "$SESSION_START"
        printf "  Stopped  : %s
" "$session_end"
        printf "  Interval : %ss  |  Samples : %d
" "$INTERVAL" "$row"
        [ -n "$LOG_FILE" ] && printf "  Log file : %s
" "$LOG_FILE"
        printf "
"

        for iface in $IFACES; do
            n=${acc_intervals[$iface]}
            [ "$n" -eq 0 ] && continue

            total_xdp=${acc_xdp[$iface]}
            total_drp=${acc_drp[$iface]}
            total_fwd=${acc_fwd[$iface]}
            total_rxk=${acc_rxk[$iface]}
            total_txk=${acc_txk[$iface]}

            avg_xdp_pps=$(( total_xdp / n / INTERVAL ))
            avg_drp_pps=$(( total_drp / n / INTERVAL ))
            avg_fwd_pps=$(( total_fwd / n / INTERVAL ))
            avg_rxk_ps=$(( total_rxk / n / INTERVAL ))

            avg_drop_pct=0
            [ "$total_xdp" -gt 0 ] &&                 avg_drop_pct=$(( total_drp * 100 / total_xdp ))

            printf "  ── %s ──────────────────────────────────────────────
" "$iface"
            printf "  %-28s %d pkts  (avg %d pps)
"                 "Total XDP received:"   "$total_xdp" "$avg_xdp_pps"
            printf "  %-28s %d pkts  (avg %d pps)  [%d%%]
"                 "Total XDP dropped:"    "$total_drp" "$avg_drp_pps" "$avg_drop_pct"
            printf "  %-28s %d pkts  (avg %d pps)
"                 "Total forwarded:"      "$total_fwd" "$avg_fwd_pps"
            printf "  %-28s %d  (avg %d /s)
"                 "Total rx_kicks:"       "$total_rxk" "$avg_rxk_ps"
            printf "  %-28s %d  (avg %d /s)
"                 "Total tx_kicks:"       "$total_txk" "$avg_rxk_ps"
            printf "  %-28s %d%%  @ %s
"                 "Worst drop interval:"  "${worst_drop_pct[$iface]}" "${worst_drop_ts[$iface]}"
            printf "  %-28s %d pps
"                 "Best fwd interval:"    "${best_fwd_pps[$iface]}"
            printf "
"

            # Verdict
            if [ "$avg_drop_pct" -gt 80 ]; then
                printf "  ✗ VERDICT: FILL_STARVE — avg drop rate %d%% — fill ring chronically empty
"                     "$avg_drop_pct"
                printf "    → Remove force_copy=1, add --nb-cores, check busy-poll config
"
            elif [ "$avg_drop_pct" -gt 20 ]; then
                printf "  ⚠ VERDICT: DEGRADED   — avg drop rate %d%% — partial starvation
"                     "$avg_drop_pct"
            elif [ "$avg_rxk_ps" -gt 500 ]; then
                printf "  ⚠ VERDICT: KICK_STORM — avg rx_kicks/s=%d — busy-poll not holding
"                     "$avg_rxk_ps"
            else
                printf "  ✓ VERDICT: STABLE     — avg drop rate %d%%
" "$avg_drop_pct"
            fi
            printf "
"
        done
        printf "══════════════════════════════════════════════════════════════════════
"
    } | tee /dev/fd/3 >/dev/null 2>/dev/null ||     {
        # tee to fd3 failed (fd3 already closed) — just print normally
        printf "
(summary already printed above)
"
    }
    exit 0
}

print_header() {
    printf "\n%-22s %-10s %10s %10s %8s %10s %10s %10s  %s\n" \
        "Timestamp" "iface" "xdp_pps" "drop_pps" "drop%" "fwd_pps" "rx_kicks/s" "tx_kicks/s" "status"
    printf "%-22s %-10s %10s %10s %8s %10s %10s %10s  %s\n" \
        "----------------------" "----------" "----------" "----------" "--------" "----------" "----------" "----------" "----------"
}

get_counter() {
    # $1=iface $2=counter_name
    ethtool -S "$1" 2>/dev/null | awk -v key="$2" '
        $0 ~ key {
            # take first match only (avoid rx0_ prefix duplicates)
            gsub(/:/, "", $NF)
            print $(NF-0)+0
            exit
        }'
}

get_proc_net_xdp() {
    # Parse /proc/net/xdp — shows per-socket: rx_dropped, fill_ring_empty, etc.
    # Output: one line per XSK socket
    if [ -r /proc/net/xdp ]; then
        # Format: Name  ID  Flags  Ifindex  Queue  Umem  Fill  Comp  ...  fill_ring_empty
        awk 'NR>2 {print}' /proc/net/xdp 2>/dev/null
    fi
}

get_fdinfo_rings() {
    # Read XSK ring positions from testpmd fdinfo
    local tpmd_pid
    tpmd_pid=$(pgrep -f dpdk-testpmd 2>/dev/null | head -1)
    [ -z "$tpmd_pid" ] && return

    local found=0
    for fd in /proc/$tpmd_pid/fd/*; do
        link=$(readlink "$fd" 2>/dev/null)
        [ -z "$link" ] && continue
        echo "$link" | grep -q "socket:" || continue
        inode=$(echo "$link" | grep -oP '\d+')
        # Check if this inode is an XDP socket
        if grep -q "$inode" /proc/net/xdp 2>/dev/null; then
            fd_num=$(basename "$fd")
            fdinfo=$(cat "/proc/$tpmd_pid/fdinfo/$fd_num" 2>/dev/null)
            if [ -n "$fdinfo" ]; then
                found=$((found+1))
                printf "  XSK fd=%-4s " "$fd_num"
                echo "$fdinfo" | grep -E "rx_ring|tx_ring|fill_ring|comp_ring|umem" | \
                    tr '\n' '  '
                echo
            fi
        fi
    done
    [ "$found" -eq 0 ] && printf "  (no XSK fds found for testpmd pid=$tpmd_pid)\n"
}

# Check dependencies
for cmd in ethtool; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
done

# ── Log file setup ─────────────────────────────────────────────────────────
if [ "$LOG_ARG" = "-" ]; then
    LOG_FILE=""
    LOGGING="disabled"
elif [ -n "$LOG_ARG" ]; then
    LOG_FILE="$LOG_ARG"
    LOGGING="$LOG_FILE"
else
    LOG_FILE="/tmp/xsk_monitor_$(date +%Y%m%d_%H%M%S).log"
    LOGGING="$LOG_FILE"
fi

# Redirect all stdout through tee if logging is enabled.
# We reopen stdout on fd 3 so the exit-summary function can write to the
# terminal directly (bypassing tee) when tee has already exited.
if [ -n "$LOG_FILE" ]; then
    exec 3>&1                          # save original stdout
    exec > >(tee -a "$LOG_FILE") 2>&1  # tee everything to log + terminal
else
    exec 3>&1
fi

# Trap Ctrl+C and normal exit to print summary
trap print_summary INT TERM EXIT

echo "=== XSK Monitor started $(date) ==="
echo "=== Interfaces: $IFACES | Interval: ${INTERVAL}s ==="
[ -n "$LOG_FILE" ] && echo "=== Logging to: $LOG_FILE ===" || echo "=== File logging: disabled ==="
echo ""

# Warm up prev values
for iface in $IFACES; do
    prev_xdp[$iface]=$(get_counter "$iface" "rx_xdp_packets")
    prev_drops[$iface]=$(get_counter "$iface" "rx_xdp_drops")
    prev_redir[$iface]=$(get_counter "$iface" "rx_xdp_redirects")
    prev_rxk[$iface]=$(get_counter "$iface" "rx_kicks")
    prev_txk[$iface]=$(get_counter "$iface" "tx_kicks")
done

sleep "$INTERVAL"

while true; do
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    if (( row % header_every == 0 )); then
        print_header
    fi

    for iface in $IFACES; do
        xdp=$(get_counter "$iface" "rx_xdp_packets")
        drp=$(get_counter "$iface" "rx_xdp_drops")
        redir=$(get_counter "$iface" "rx_xdp_redirects")
        rxk=$(get_counter "$iface" "rx_kicks")
        txk=$(get_counter "$iface" "tx_kicks")

        # Deltas
        d_xdp=$(( ${xdp:-0}  - ${prev_xdp[$iface]:-0}  ))
        d_drp=$(( ${drp:-0}  - ${prev_drops[$iface]:-0} ))
        d_rdr=$(( ${redir:-0} - ${prev_redir[$iface]:-0} ))
        d_rxk=$(( ${rxk:-0}  - ${prev_rxk[$iface]:-0}  ))
        d_txk=$(( ${txk:-0}  - ${prev_txk[$iface]:-0}  ))

        # Guard against counter resets
        [ "$d_xdp" -lt 0 ] && d_xdp=0
        [ "$d_drp" -lt 0 ] && d_drp=0
        [ "$d_rxk" -lt 0 ] && d_rxk=0
        [ "$d_txk" -lt 0 ] && d_txk=0

        # Rates (per second)
        d_xdp_ps=$(( d_xdp / INTERVAL ))
        d_drp_ps=$(( d_drp / INTERVAL ))
        d_fwd_ps=$(( (d_xdp - d_drp) / INTERVAL ))
        d_rxk_ps=$(( d_rxk / INTERVAL ))
        d_txk_ps=$(( d_txk / INTERVAL ))

        # Drop percentage
        drop_pct=0
        [ "$d_xdp" -gt 0 ] && drop_pct=$(( d_drp * 100 / d_xdp ))

        # Status classification
        if [ "$d_xdp_ps" -lt 1000 ]; then
            status="IDLE"
        elif [ "$drop_pct" -gt 80 ] && [ "$d_rxk_ps" -lt 50 ]; then
            status="FILL_STARVE ◄◄"   # fill ring chronically empty, busy-poll can't help
        elif [ "$drop_pct" -gt 80 ] && [ "$d_rxk_ps" -ge 50 ]; then
            status="STARVE+KICKS"      # fill ring empty AND wakeup path overwhelmed
        elif [ "$drop_pct" -gt 20 ]; then
            status="DEGRADED"
        elif [ "$d_rxk_ps" -gt 500 ]; then
            status="KICK_STORM"        # too many wakeups — busy-poll not working
        elif [ "$drop_pct" -lt 5 ] && [ "$d_xdp_ps" -gt 1000 ]; then
            status="STABLE ✓"
        else
            status="OK"
        fi

        printf "%-22s %-10s %10d %10d %7d%% %10d %10d %10d  %s\n" \
            "$ts" "$iface" "$d_xdp_ps" "$d_drp_ps" "$drop_pct" \
            "$d_fwd_ps" "$d_rxk_ps" "$d_txk_ps" "$status"

        # Update prev
        prev_xdp[$iface]=$xdp
        prev_drops[$iface]=$drp
        prev_redir[$iface]=$redir
        prev_rxk[$iface]=$rxk
        prev_txk[$iface]=$txk

        # Accumulate session totals
        acc_xdp[$iface]=$(( ${acc_xdp[$iface]} + d_xdp ))
        acc_drp[$iface]=$(( ${acc_drp[$iface]} + d_drp ))
        acc_fwd[$iface]=$(( ${acc_fwd[$iface]} + d_xdp - d_drp ))
        acc_rxk[$iface]=$(( ${acc_rxk[$iface]} + d_rxk ))
        acc_txk[$iface]=$(( ${acc_txk[$iface]} + d_txk ))
        acc_intervals[$iface]=$(( ${acc_intervals[$iface]} + 1 ))

        # Track worst drop interval and best forward interval
        if [ "$drop_pct" -gt "${worst_drop_pct[$iface]}" ]; then
            worst_drop_pct[$iface]=$drop_pct
            worst_drop_ts[$iface]=$ts
        fi
        if [ "$d_fwd_ps" -gt "${best_fwd_pps[$iface]}" ]; then
            best_fwd_pps[$iface]=$d_fwd_ps
        fi
    done

    # Every 10 rows: show /proc/net/xdp fill_ring_empty if available
    if (( row % 10 == 0 )) && [ -r /proc/net/xdp ]; then
        xdp_info=$(awk 'NR==1{print; next} NR>1{print}' /proc/net/xdp 2>/dev/null)
        if [ -n "$xdp_info" ]; then
            echo ""
            echo "  /proc/net/xdp:"
            echo "$xdp_info" | head -5 | sed 's/^/    /'
        fi
    fi

    # Every 30 rows: show fdinfo ring positions (expensive)
    if (( row % 30 == 0 )); then
        echo ""
        echo "  XSK fdinfo ring positions:"
        get_fdinfo_rings
    fi

    row=$(( row + 1 ))
    sleep "$INTERVAL"
done
