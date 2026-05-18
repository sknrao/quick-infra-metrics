#!/usr/bin/env python3
"""
analyze_net_hugepage.py — parse and summarize output from net_hugepage_monitor.sh

Usage:
    # Single file (VM or host alone)
    python3 analyze_net_hugepage.py /tmp/net_hugepage_vm_*.log

    # Both files together (recommended — shows host↔VM counter correlation)
    python3 analyze_net_hugepage.py /tmp/net_hugepage_host_*.log \\
                                    /tmp/net_hugepage_vm_*.log

What it reports:
  1. Interface counter deltas (first→last sample): RX/TX packets, bytes, errors, drops
  2. Per-sample rate table for key interfaces (pps and Mbps)
  3. XDP-specific counters: xdp_packets, xdp_redirects, xdp_drops, rx/tx_kicks
  4. Hugepage usage timeline: total/free/reserved across all samples
  5. Hugepage delta: how much DPDK consumed during the run
  6. Cross-side correlation: host vhost TX vs VM enp0s3 RX (if both files supplied)
  7. Warnings: drops, XDP redirect failures, hugepage exhaustion, kick storms

Dependencies: Python 3.7+ stdlib only.
"""

import sys
import re
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional

# ─────────────────────────────────────────────────────────────────────────────
# Data structures
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class IfaceCounters:
    rx_bytes:   int = 0
    rx_packets: int = 0
    rx_errors:  int = 0
    rx_dropped: int = 0
    rx_missed:  int = 0
    tx_bytes:   int = 0
    tx_packets: int = 0
    tx_errors:  int = 0
    tx_dropped: int = 0
    # XDP / ethtool extended
    xdp_packets:   int = 0
    xdp_redirects: int = 0
    xdp_drops:     int = 0
    rx_kicks:      int = 0
    tx_kicks:      int = 0

    def total_rx(self): return self.rx_packets
    def total_tx(self): return self.tx_packets

@dataclass
class HugepageSnapshot:
    timestamp: str = ""
    total_2m:  int = 0
    free_2m:   int = 0
    rsvd_2m:   int = 0
    total_1g:  int = 0
    free_1g:   int = 0
    rsvd_1g:   int = 0
    # raw /proc/meminfo fields
    meminfo:   dict = field(default_factory=dict)

@dataclass
class Sample:
    timestamp: str
    ifaces: dict           # iface_name → IfaceCounters
    hugepages: HugepageSnapshot
    is_baseline: bool = False   # True for the T=0 snapshot; excluded from timeseries

# ─────────────────────────────────────────────────────────────────────────────
# Parser
# ─────────────────────────────────────────────────────────────────────────────

def parse_log(path):
    """Parse a net_hugepage_monitor log. Returns list[Sample] and a metadata dict."""

    samples   = []
    metadata  = {}
    label     = "unknown"

    current_ts       = None
    current_ifaces   = {}
    current_hp       = None
    current_iface    = None
    current_baseline = False   # True when parsing a BASELINE block
    section          = None    # "IFACES" | "HUGEPAGES" | "STATIC" | None

    # ip -s link output parsing state
    # We track which line of the ip stats block we're on
    ip_rx_line_next = False
    ip_tx_line_next = False

    def flush_sample():
        nonlocal current_ifaces, current_hp, current_iface, current_baseline
        if current_ts and current_ifaces:
            samples.append(Sample(
                timestamp=current_ts,
                ifaces=dict(current_ifaces),
                hugepages=current_hp or HugepageSnapshot(timestamp=current_ts),
                is_baseline=current_baseline,
            ))
        current_ifaces   = {}
        current_hp       = None
        current_iface    = None
        current_baseline = False

    with open(path, errors="replace") as fh:
        lines = fh.readlines()

    i = 0
    while i < len(lines):
        raw  = lines[i].rstrip()
        line = raw.strip()
        i   += 1

        # File header
        if raw.startswith("=== label="):
            m = re.search(r'label=(\S+)', raw)
            if m:
                label = m.group(1)
            metadata["label"] = label
            continue

        if raw.startswith("=== started="):
            metadata["started"] = raw.replace("=== started=", "").strip(" =")
            continue

        # Section boundary: new BASELINE or SAMPLE block
        m = re.match(r'════ (BASELINE|SAMPLE)\s+(.+?)\s+════', raw)
        if m:
            flush_sample()
            current_baseline = (m.group(1) == "BASELINE")
            current_ts       = m.group(2).strip()
            section          = None
            ip_rx_line_next  = False
            ip_tx_line_next  = False
            continue

        if "=IFACES=" in raw:
            section = "IFACES"
            continue

        if "=HUGEPAGES=" in raw:
            section = "HUGEPAGES"
            current_hp = HugepageSnapshot(timestamp=current_ts or "")
            continue

        if "====== STATIC CONFIG" in raw or "==============================" in raw:
            section = "STATIC"
            continue

        # ── INTERFACE PARSING ────────────────────────────────────────────────
        if section == "IFACES":

            # New interface block
            m = re.match(r'\s*---\s+(\S+)\s+---', line)
            if m:
                current_iface = m.group(1)
                if current_iface not in current_ifaces:
                    current_ifaces[current_iface] = IfaceCounters()
                ip_rx_line_next = False
                ip_tx_line_next = False
                continue

            if current_iface is None:
                continue

            ctr = current_ifaces[current_iface]

            # ip -s link RX/TX block.
            # Format after "ip -s link show | tail -n +2":
            #   link/ether ...
            #   RX:    bytes   packets errors   dropped  missed   mcast
            #   <numbers>
            #   TX:    bytes   packets errors   dropped carrier collsns
            #   <numbers>
            if re.match(r'\s*RX:\s+bytes', line):
                ip_rx_line_next = True
                ip_tx_line_next = False
                continue
            if re.match(r'\s*TX:\s+bytes', line):
                ip_tx_line_next = True
                ip_rx_line_next = False
                continue

            if ip_rx_line_next:
                nums = re.findall(r'\d+', line)
                if len(nums) >= 4:
                    ctr.rx_bytes   = int(nums[0])
                    ctr.rx_packets = int(nums[1])
                    ctr.rx_errors  = int(nums[2])
                    ctr.rx_dropped = int(nums[3])
                    if len(nums) >= 5:
                        ctr.rx_missed = int(nums[4])
                ip_rx_line_next = False
                continue

            if ip_tx_line_next:
                nums = re.findall(r'\d+', line)
                if len(nums) >= 4:
                    ctr.tx_bytes   = int(nums[0])
                    ctr.tx_packets = int(nums[1])
                    ctr.tx_errors  = int(nums[2])
                    ctr.tx_dropped = int(nums[3])
                ip_tx_line_next = False
                continue

            # ethtool -S extended stats (non-zero only)
            m = re.match(r'\s*(rx_xdp_packets|rx_xdp_redirects|rx_xdp_drops|'
                         r'rx_drops|rx_kicks|tx_kicks)\s*:\s*(\d+)', line)
            if m:
                key, val = m.group(1), int(m.group(2))
                if key == "rx_xdp_packets":   ctr.xdp_packets   = val
                if key == "rx_xdp_redirects": ctr.xdp_redirects = val
                if key in ("rx_xdp_drops", "rx_drops"): ctr.xdp_drops = val
                if key == "rx_kicks":          ctr.rx_kicks      = val
                if key == "tx_kicks":          ctr.tx_kicks      = val
                continue

        # ── HUGEPAGE PARSING ─────────────────────────────────────────────────
        if section == "HUGEPAGES" and current_hp is not None:

            # /proc/meminfo lines
            m = re.match(r'\s*(HugePages_\w+)\s*:\s*(\d+)', line)
            if m:
                current_hp.meminfo[m.group(1)] = int(m.group(2))
                continue

            # per-NUMA sysfs line:  node0  hugepages-2048kB  total=X  free=Y  rsvd=Z  surp=W
            m = re.match(r'\s*(node\d+)\s+(hugepages-(\d+)kB)\s+total=(\d+)\s+free=(\d+)\s+rsvd=(\d+)', line)
            if m:
                size_kb = int(m.group(3))
                total, free, rsvd = int(m.group(4)), int(m.group(5)), int(m.group(6))
                if size_kb == 2048:
                    current_hp.total_2m += total
                    current_hp.free_2m  += free
                    current_hp.rsvd_2m  += rsvd
                elif size_kb == 1048576:
                    current_hp.total_1g += total
                    current_hp.free_1g  += free
                    current_hp.rsvd_1g  += rsvd
                continue

    flush_sample()
    return samples, metadata

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def delta(a, b):
    """Counter delta b - a (handle counter resets by returning 0 if negative)."""
    d = b - a
    return d if d >= 0 else b   # counter reset: just report new value

def rate(val, dt_sec):
    return val / dt_sec if dt_sec > 0 else 0.0

def fmt_pps(n):
    if n >= 1_000_000: return f"{n/1_000_000:.2f}M"
    if n >= 1_000:     return f"{n/1_000:.1f}K"
    return str(n)

def fmt_bps(n):
    if n >= 1e9:  return f"{n/1e9:.2f} Gbps"
    if n >= 1e6:  return f"{n/1e6:.1f} Mbps"
    if n >= 1e3:  return f"{n/1e3:.1f} Kbps"
    return f"{n:.0f} bps"

def parse_ts(ts_str):
    """Loosely parse a timestamp string to seconds-of-day for rate calculations."""
    m = re.search(r'(\d{2}):(\d{2}):(\d{2})', ts_str)
    if not m: return None
    h, mn, s = int(m.group(1)), int(m.group(2)), int(m.group(3))
    return h * 3600 + mn * 60 + s

def ts_diff(a, b):
    ta, tb = parse_ts(a), parse_ts(b)
    if ta is None or tb is None: return 2  # assume interval
    d = tb - ta
    return d if d > 0 else 2

W = 80
SEP  = "─" * W
SEP2 = "═" * W

def hdr(t):
    print(f"\n{SEP2}\n  {t}\n{SEP2}")

def subhdr(t):
    print(f"\n{t}\n{SEP}")

# ─────────────────────────────────────────────────────────────────────────────
# Report sections
# ─────────────────────────────────────────────────────────────────────────────

def report_iface_deltas(samples, label):
    """Total counter deltas: baseline→last sample (or first→last if no baseline)."""
    # Separate baseline from regular samples
    baselines = [s for s in samples if s.is_baseline]
    regulars  = [s for s in samples if not s.is_baseline]

    if not regulars:
        print("  (no regular samples found)")
        return {}

    # Origin for subtraction: explicit T=0 baseline if present, else first sample
    origin = baselines[0] if baselines else regulars[0]
    last   = regulars[-1]

    if baselines:
        print(f"  ✓ Using T=0 baseline ({origin.timestamp}) — pre-existing traffic excluded.")
    else:
        print(f"  ⚠ No BASELINE found — using first sample as origin (upgrade monitor script).")

    all_ifaces = sorted(set(origin.ifaces) | set(last.ifaces))

    total_dt  = ts_diff(origin.timestamp, last.timestamp)
    n_samples = len(regulars)

    FMT = "{:<16} {:>12} {:>12} {:>10} {:>10} {:>10}  {:>10} {:>12}"
    print(f"  Label: {label}  |  samples: {n_samples}  |  "
          f"window: {origin.timestamp} → {last.timestamp}  ({total_dt}s)")
    print()
    print(FMT.format("Interface", "RX pkts", "TX pkts",
                     "RX drops", "RX errs", "TX drops",
                     "RX Mpps", "TX Mpps"))
    print("  " + SEP)

    deltas = {}
    for iface in all_ifaces:
        a = origin.ifaces.get(iface, IfaceCounters())
        b = last.ifaces.get(iface, IfaceCounters())
        d = IfaceCounters(
            rx_bytes=delta(a.rx_bytes,   b.rx_bytes),
            rx_packets=delta(a.rx_packets, b.rx_packets),
            rx_errors=delta(a.rx_errors,  b.rx_errors),
            rx_dropped=delta(a.rx_dropped, b.rx_dropped),
            rx_missed=delta(a.rx_missed,  b.rx_missed),
            tx_bytes=delta(a.tx_bytes,   b.tx_bytes),
            tx_packets=delta(a.tx_packets, b.tx_packets),
            tx_errors=delta(a.tx_errors,  b.tx_errors),
            tx_dropped=delta(a.tx_dropped, b.tx_dropped),
            xdp_packets=delta(a.xdp_packets,   b.xdp_packets),
            xdp_redirects=delta(a.xdp_redirects, b.xdp_redirects),
            xdp_drops=delta(a.xdp_drops,     b.xdp_drops),
            rx_kicks=delta(a.rx_kicks, b.rx_kicks),
            tx_kicks=delta(a.tx_kicks, b.tx_kicks),
        )
        deltas[iface] = d
        rx_mpps = d.rx_packets / total_dt / 1e6 if total_dt else 0
        tx_mpps = d.tx_packets / total_dt / 1e6 if total_dt else 0

        drop_warn = " ⚠" if d.rx_dropped > 1000 else ""
        print(("  " + FMT).format(
            iface[:15],
            f"{d.rx_packets:,}",
            f"{d.tx_packets:,}",
            f"{d.rx_dropped:,}{drop_warn}",
            f"{d.rx_errors:,}",
            f"{d.tx_dropped:,}",
            f"{rx_mpps:.4f}",
            f"{tx_mpps:.4f}",
        ))

        if d.xdp_packets > 0:
            drop_pct = d.xdp_drops / d.xdp_packets * 100 if d.xdp_packets else 0
            redir_pct = d.xdp_redirects / d.xdp_packets * 100 if d.xdp_packets else 0
            print(f"    XDP: pkts={d.xdp_packets:,}  redirects={d.xdp_redirects:,}"
                  f"({redir_pct:.1f}%)  drops={d.xdp_drops:,}({drop_pct:.1f}%)"
                  f"  rx_kicks={d.rx_kicks}  tx_kicks={d.tx_kicks}")

    return deltas


def report_rate_timeseries(samples, label, key_ifaces=None):
    """Per-sample RX/TX pps rates for the most interesting interfaces."""
    if len(samples) < 2:
        return

    if key_ifaces is None:
        # Auto-select: interfaces that had any traffic
        first, last = samples[0], samples[-1]
        key_ifaces = [
            iface for iface in sorted(set(first.ifaces) | set(last.ifaces))
            if delta(first.ifaces.get(iface, IfaceCounters()).rx_packets,
                     last.ifaces.get(iface, IfaceCounters()).rx_packets) > 100
        ]
        if not key_ifaces:
            key_ifaces = sorted((set(samples[0].ifaces) | set(samples[-1].ifaces)))

    # Cap at 6 interfaces for readability
    key_ifaces = key_ifaces[:6]

    print(f"  Label: {label}  |  interfaces tracked: {', '.join(key_ifaces)}")
    print(f"  (rates are per-sample-interval averages in Kpps)")
    print()

    # Header
    col_w = 10
    header = f"{'Timestamp':<22}" + "".join(f"{iface[:col_w-1]:>{col_w}}" for iface in key_ifaces)
    print("  " + header)
    print("  " + "-" * len(header))

    # Use baseline as the fixed subtraction origin for all samples so rates
    # reflect traffic since T=0, not since the previous polling interval.
    # For interval rates (more useful for spotting spikes) we diff consecutive samples.
    baselines = [s for s in samples if s.is_baseline]
    regulars  = [s for s in samples if not s.is_baseline]
    if not regulars:
        print("  (no regular samples)")
        return

    prev = regulars[0]
    for s in regulars[1:]:
        dt = ts_diff(prev.timestamp, s.timestamp)
        row = f"{s.timestamp:<22}"
        for iface in key_ifaces:
            a = prev.ifaces.get(iface, IfaceCounters())
            b = s.ifaces.get(iface, IfaceCounters())
            rx_kpps = delta(a.rx_packets, b.rx_packets) / dt / 1000 if dt else 0
            row += f"{rx_kpps:>{col_w}.1f}"
        print("  " + row)
        prev = s


def report_hugepages(samples, label):
    """Hugepage usage across all samples."""
    if not samples:
        return

    regulars = [s for s in samples if not s.is_baseline]
    baselines = [s for s in samples if s.is_baseline]
    # For hugepages, baseline is the T=0 reference; last is end of experiment
    first_hp = (baselines[0] if baselines else (regulars[0] if regulars else samples[0])).hugepages
    last_hp  = (regulars[-1] if regulars else samples[-1]).hugepages

    print(f"  Label: {label}")
    print()

    # Check what page sizes are present
    has_2m = any(s.hugepages.total_2m > 0 for s in samples)
    has_1g = any(s.hugepages.total_1g > 0 for s in samples)
    has_meminfo = any(s.hugepages.meminfo for s in samples)

    if has_meminfo:
        # /proc/meminfo-based summary (most reliable)
        FMT = "{:<28} {:>10} {:>10}"
        print(f"  {'Field':<28} {'First':>10} {'Last':>10}")
        print("  " + "-" * 50)
        meminfo_keys = ["HugePages_Total", "HugePages_Free", "HugePages_Rsvd",
                        "HugePages_Surp", "Hugepagesize",
                        "HugePages_Total", "HugePages_Free"]
        seen = set()
        all_keys = []
        for s in samples:
            for k in s.hugepages.meminfo:
                if k not in seen:
                    all_keys.append(k)
                    seen.add(k)
        for k in all_keys:
            v_first = first_hp.meminfo.get(k, "—")
            v_last  = last_hp.meminfo.get(k, "—")
            changed = " ◀" if v_first != v_last else ""
            print(("  " + FMT).format(k, str(v_first), str(v_last)) + changed)
        print()

    if has_2m or has_1g:
        print("  Per-NUMA page summary (first → last sample):")
        if has_2m:
            d_free_2m = first_hp.free_2m - last_hp.free_2m
            print(f"    2MB pages : total={last_hp.total_2m}  free={last_hp.free_2m}"
                  f"  rsvd={last_hp.rsvd_2m}  consumed={d_free_2m} during run")
        if has_1g:
            d_free_1g = first_hp.free_1g - last_hp.free_1g
            print(f"    1GB pages : total={last_hp.total_1g}  free={last_hp.free_1g}"
                  f"  rsvd={last_hp.rsvd_1g}  consumed={d_free_1g} during run")

    # Timeline of free pages (if they change)
    print()
    print(f"  {'Timestamp':<22}  {'2MB free':>10}  {'1GB free':>10}  {'Rsvd(2M)':>10}")
    print("  " + "-" * 60)
    prev_f2 = prev_f1 = prev_r2 = None
    for s in [x for x in samples if not x.is_baseline]:
        hp = s.hugepages
        changed = (hp.free_2m != prev_f2 or hp.free_1g != prev_f1 or hp.rsvd_2m != prev_r2)
        if changed or prev_f2 is None:
            print(f"  {s.timestamp:<22}  {hp.free_2m:>10}  {hp.free_1g:>10}  {hp.rsvd_2m:>10}")
        prev_f2, prev_f1, prev_r2 = hp.free_2m, hp.free_1g, hp.rsvd_2m


def report_warnings(all_data):
    """Cross-file warnings."""
    warnings = []

    for label, (samples, _) in all_data.items():
        if len(samples) < 2:
            continue
        baselines = [s for s in samples if s.is_baseline]
        regulars  = [s for s in samples if not s.is_baseline]
        if not regulars:
            continue
        first = baselines[0] if baselines else regulars[0]
        last  = regulars[-1]
        for iface in set(first.ifaces) | set(last.ifaces):
            a = first.ifaces.get(iface, IfaceCounters())
            b = last.ifaces.get(iface, IfaceCounters())

            rx_drop = delta(a.rx_dropped, b.rx_dropped)
            rx_miss = delta(a.rx_missed,  b.rx_missed)
            xdp_pk  = delta(a.xdp_packets,   b.xdp_packets)
            xdp_dr  = delta(a.xdp_drops,     b.xdp_drops)
            rx_k    = delta(a.rx_kicks, b.rx_kicks)
            tx_k    = delta(a.tx_kicks, b.tx_kicks)

            if rx_drop > 10_000:
                pct = rx_drop / max(delta(a.rx_packets, b.rx_packets), 1) * 100
                warnings.append(f"[{label}] {iface}: {rx_drop:,} RX drops ({pct:.1f}% of RX pkts) — "
                                 f"kernel ring or XSK fill ring overflow.")

            if rx_miss > 10_000:
                warnings.append(f"[{label}] {iface}: {rx_miss:,} RX missed — "
                                 f"NIC ring too small or CPU can't drain fast enough.")

            if xdp_pk > 0:
                dr_pct = xdp_dr / xdp_pk * 100
                if dr_pct > 20:
                    warnings.append(f"[{label}] {iface}: XDP drop rate {dr_pct:.1f}% "
                                     f"({xdp_dr:,}/{xdp_pk:,}) — XSK fill ring starved. "
                                     f"Increase --nb-cores or RX descriptor ring size.")

            if rx_k > 50_000:
                warnings.append(f"[{label}] {iface}: rx_kicks={rx_k:,} — "
                                 f"XSK wakeup path used heavily; busy-poll not keeping up. "
                                 f"Check SO_BUSY_POLL timeout and CPU isolation.")

        # Hugepage warnings
        for s in [x for x in samples if not x.is_baseline]:
            hp = s.hugepages
            total_2m = hp.total_2m or hp.meminfo.get("HugePages_Total", 0)
            free_2m  = hp.free_2m  or hp.meminfo.get("HugePages_Free",  0)
            if total_2m > 0 and free_2m == 0:
                warnings.append(f"[{label}] @ {s.timestamp}: 2MB hugepages exhausted "
                                 f"(free=0/{total_2m}) — DPDK may fall back to regular pages.")
                break
            if total_2m > 0:
                used_pct = (total_2m - free_2m) / total_2m * 100
                if used_pct > 90:
                    warnings.append(f"[{label}] @ {s.timestamp}: 2MB hugepage usage at "
                                     f"{used_pct:.0f}% ({total_2m-free_2m}/{total_2m}).")
                    break

    # Cross-side check: if both host and VM provided
    labels = list(all_data.keys())
    if len(labels) == 2:
        host_label = next((l for l in labels if "host" in l.lower()), labels[0])
        vm_label   = next((l for l in labels if "vm"   in l.lower()), labels[1])

        h_s, _ = all_data[host_label]
        v_s, _ = all_data[vm_label]

        if len(h_s) >= 2 and len(v_s) >= 2:
            # Find vhost interfaces on host
            h_first, h_last = h_s[0], h_s[-1]
            vhost_ifaces = [i for i in set(h_first.ifaces) | set(h_last.ifaces)
                            if "vhost" in i.lower() or "dpdkvhost" in i.lower()]
            vm_ifaces    = [i for i in set(v_s[0].ifaces) | set(v_s[-1].ifaces)
                            if "enp" in i.lower() or "eth" in i.lower()]

            if vhost_ifaces and vm_ifaces:
                host_tx = sum(
                    delta(h_first.ifaces.get(i, IfaceCounters()).tx_packets,
                          h_last.ifaces.get(i,  IfaceCounters()).tx_packets)
                    for i in vhost_ifaces
                )
                vm_rx = sum(
                    delta(v_s[0].ifaces.get(i, IfaceCounters()).rx_packets,
                          v_s[-1].ifaces.get(i, IfaceCounters()).rx_packets)
                    for i in vm_ifaces
                )
                if host_tx > 0 and vm_rx > 0:
                    ratio = vm_rx / host_tx * 100
                    if ratio < 80:
                        warnings.append(
                            f"Cross-side: host vhost TX={host_tx:,} pkt vs VM RX={vm_rx:,} pkt "
                            f"({ratio:.1f}% delivery) — significant loss in vhost→VM path. "
                            f"Check OVS vhost n_rxq, virtio queue depth, and guest driver.")

    if warnings:
        for w in warnings:
            print(f"  ⚠  {w}")
    else:
        print("  ✓ No significant warnings.")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(f"Usage: python3 {sys.argv[0]} <log1> [log2]")
        print()
        print("  Single:  python3 analyze_net_hugepage.py /tmp/net_hugepage_vm_*.log")
        print("  Both:    python3 analyze_net_hugepage.py /tmp/net_hugepage_host_*.log \\")
        print("                                           /tmp/net_hugepage_vm_*.log")
        sys.exit(1)

    # Parse all supplied files
    all_data = {}   # label → (samples, metadata)
    for path in sys.argv[1:]:
        samples, meta = parse_log(path)
        label = meta.get("label", path.split("/")[-1])
        all_data[label] = (samples, meta)
        if not samples:
            print(f"WARNING: no samples parsed from {path}", file=sys.stderr)

    print(SEP2)
    print("  NETWORK INTERFACE + HUGEPAGE ANALYSIS")
    print(SEP2)

    for label, (samples, meta) in all_data.items():
        hdr(f"INTERFACE COUNTER DELTAS  [{label.upper()}]")
        report_iface_deltas(samples, label)

    for label, (samples, meta) in all_data.items():
        hdr(f"RX RATE TIMESERIES (Kpps per interface)  [{label.upper()}]")
        report_rate_timeseries(samples, label)

    for label, (samples, meta) in all_data.items():
        hdr(f"HUGEPAGE USAGE  [{label.upper()}]")
        report_hugepages(samples, label)

    hdr("WARNINGS & RECOMMENDATIONS")
    report_warnings(all_data)

    print(f"\n{SEP2}\n")


if __name__ == "__main__":
    main()
