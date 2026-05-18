#!/usr/bin/env python3
"""
analyze_cpu.py — parse and summarize mpstat output from cpu_monitor.sh

Usage:
    python3 analyze_cpu.py <cpu_monitor_*.log>

What it reports:
  1. Per-CPU utilization summary (avg, max, stddev) — sorted by avg %usr+%sys
  2. Hot CPUs   — cores that were consistently busy (likely testpmd lcores)
  3. Idle CPUs  — cores that were consistently idle
  4. Contention — cores shared between high-%sys and high-%usr (bad: IRQ on testpmd core)
  5. Timeseries — per-second table of the top-N busiest cores so you can see
                  if utilization is stable or spiky
  6. Recommendations — actionable notes based on the data

Dependencies: Python 3.7+ stdlib only (no pandas/numpy required)
"""

import sys
import re
import math
from collections import defaultdict
from datetime import datetime

# ── tunables ────────────────────────────────────────────────────────────────

BUSY_THRESHOLD   = 70.0   # % total CPU use to call a core "hot"
IDLE_THRESHOLD   = 5.0    # % total CPU use to call a core "idle"
SYS_WARN         = 15.0   # % sys on a core that should be userspace-only → IRQ suspect
TOP_N_TIMESERIES = 8      # how many busiest CPUs to include in the timeseries table

# ── parser ───────────────────────────────────────────────────────────────────

def parse_mpstat(path):
    """
    Parse mpstat -P ALL output.
    Returns:
        samples  : list of dicts  { timestamp, cpu, usr, nice, sys, iowait, irq, soft, idle }
        metadata : dict           { host, topology_lines, affinity_start, affinity_stop }
    """
    samples  = []
    metadata = {"topology": [], "affinity_start": [], "affinity_stop": []}
    section  = None
    current_ts = None

    # mpstat timestamp lines look like:
    #   03:15:11 PM  all    1.23  0.00  0.45 ...
    #   03:15:11 PM    0    5.00  0.00  1.20 ...
    # Some locales use 24h without AM/PM — handle both.
    TS_RE = re.compile(r'^(\d{2}:\d{2}:\d{2}(?:\s+[AP]M)?)\s+(\S+)\s+(.+)$')

    in_affinity_stop = False

    with open(path, "r", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip()

            # Section markers
            if "CPU topology" in line or "NUMA layout" in line:
                section = "topology"
                continue
            if "CPU affinity snapshot at start" in line:
                section = "affinity_start"
                continue
            if "CPU affinity snapshot at stop" in line:
                section = "affinity_stop"
                continue
            if "mpstat per-CPU samples" in line:
                section = "mpstat"
                continue

            if section == "topology":
                metadata["topology"].append(line)
                continue
            if section == "affinity_start":
                metadata["affinity_start"].append(line)
                continue
            if section == "affinity_stop":
                metadata["affinity_stop"].append(line)
                continue

            if section != "mpstat":
                continue

            # Skip header rows
            if re.match(r'\s*(Linux|CPU|Average)', line):
                continue

            m = TS_RE.match(line)
            if not m:
                continue

            ts_str, cpu_id, rest = m.group(1), m.group(2), m.group(3)

            # Skip 'all' aggregate — we want per-core
            if cpu_id.lower() == "all":
                current_ts = ts_str
                continue

            try:
                cpu_num = int(cpu_id)
            except ValueError:
                continue

            fields = rest.split()
            # mpstat field order (varies slightly by version):
            # %usr %nice %sys %iowait %irq %soft %steal %guest %gnice %idle
            # OR (older):
            # %user %nice %system %iowait %irq %softirq %steal %guest %gnice %idle
            try:
                usr    = float(fields[0])
                nice   = float(fields[1])
                sys_   = float(fields[2])
                iowait = float(fields[3])
                irq    = float(fields[4])
                soft   = float(fields[5])
                # fields[6]=steal, [7]=guest, [8]=gnice, [9]=idle  (10 fields)
                # older: steal guest gnice idle  (9 fields after usr..soft)
                idle   = float(fields[-1])
            except (IndexError, ValueError):
                continue

            samples.append({
                "ts":     ts_str,
                "cpu":    cpu_num,
                "usr":    usr,
                "nice":   nice,
                "sys":    sys_,
                "iowait": iowait,
                "irq":    irq,
                "soft":   soft,
                "idle":   idle,
                "total":  100.0 - idle,
            })

    return samples, metadata

# ── statistics helpers ────────────────────────────────────────────────────────

def mean(vals):
    return sum(vals) / len(vals) if vals else 0.0

def stddev(vals):
    if len(vals) < 2:
        return 0.0
    m = mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / len(vals))

def pct(n, d):
    return (n / d * 100) if d else 0.0

# ── main analysis ─────────────────────────────────────────────────────────────

def analyze(path):
    samples, meta = parse_mpstat(path)

    if not samples:
        print("ERROR: No per-CPU mpstat samples found in the log.")
        print("       Check that the file was produced by cpu_monitor.sh")
        sys.exit(1)

    # Collect per-CPU time-series
    by_cpu = defaultdict(list)
    for s in samples:
        by_cpu[s["cpu"]].append(s)

    all_cpus = sorted(by_cpu.keys())
    num_cpus = len(all_cpus)
    total_samples = len(samples) // max(num_cpus, 1)

    # Per-CPU summary statistics
    cpu_stats = {}
    for cpu, recs in by_cpu.items():
        totals  = [r["total"]  for r in recs]
        usrs    = [r["usr"]    for r in recs]
        syss    = [r["sys"]    for r in recs]
        irqs    = [r["irq"] + r["soft"] for r in recs]
        cpu_stats[cpu] = {
            "avg_total":  mean(totals),
            "max_total":  max(totals),
            "std_total":  stddev(totals),
            "avg_usr":    mean(usrs),
            "max_usr":    max(usrs),
            "avg_sys":    mean(syss),
            "max_sys":    max(syss),
            "avg_irq":    mean(irqs),
            "max_irq":    max(irqs),
            "n_samples":  len(recs),
        }

    # Classify cores
    hot_cpus  = [c for c, s in cpu_stats.items() if s["avg_total"] >= BUSY_THRESHOLD]
    idle_cpus = [c for c, s in cpu_stats.items() if s["avg_total"] <= IDLE_THRESHOLD]
    mid_cpus  = [c for c, s in cpu_stats.items()
                 if IDLE_THRESHOLD < s["avg_total"] < BUSY_THRESHOLD]

    # Contention: cores that are hot AND have non-trivial sys/irq
    contended = [c for c in hot_cpus if cpu_stats[c]["avg_sys"] >= SYS_WARN or
                                         cpu_stats[c]["avg_irq"] >= SYS_WARN]

    # ── print report ────────────────────────────────────────────────────────

    W = 80
    SEP = "─" * W

    def hdr(title):
        print(f"\n{'═' * W}")
        print(f"  {title}")
        print(f"{'═' * W}")

    def subhdr(title):
        print(f"\n{title}")
        print(SEP)

    hdr("CPU UTILIZATION ANALYSIS")

    # Metadata
    print(f"\n  Log file : {path}")
    print(f"  CPUs seen: {num_cpus}   |   Samples per CPU: {total_samples}")

    if meta["affinity_start"]:
        print("\n  Affinity at START:")
        for ln in meta["affinity_start"]:
            if ln.strip():
                print(f"    {ln.strip()}")
    if meta["affinity_stop"]:
        print("\n  Affinity at STOP:")
        for ln in meta["affinity_stop"]:
            if ln.strip():
                print(f"    {ln.strip()}")

    # ── 1. Per-CPU summary table ─────────────────────────────────────────────
    subhdr("1. Per-CPU utilization summary  (sorted by avg total%)")

    sorted_cpus = sorted(all_cpus, key=lambda c: cpu_stats[c]["avg_total"], reverse=True)
    FMT = "{:>6}  {:>8}  {:>8}  {:>8}  {:>8}  {:>8}  {:>8}  {:>8}"
    print(FMT.format("CPU", "avg%tot", "max%tot", "std%tot", "avg%usr", "avg%sys", "avg%irq", "samples"))
    print(SEP)
    for cpu in sorted_cpus:
        s = cpu_stats[cpu]
        flag = ""
        if s["avg_total"] >= BUSY_THRESHOLD:
            flag = " ◀ HOT"
        elif s["avg_total"] <= IDLE_THRESHOLD:
            flag = " · idle"
        if cpu in contended:
            flag += " [IRQ?]"
        print(FMT.format(
            cpu,
            f"{s['avg_total']:6.1f}",
            f"{s['max_total']:6.1f}",
            f"{s['std_total']:6.1f}",
            f"{s['avg_usr']:6.1f}",
            f"{s['avg_sys']:6.1f}",
            f"{s['avg_irq']:6.1f}",
            s["n_samples"],
        ) + flag)

    # ── 2. Classification ────────────────────────────────────────────────────
    subhdr("2. Core classification")

    fmt_list = lambda lst: ", ".join(str(c) for c in sorted(lst)) if lst else "none"
    print(f"  HOT   (≥{BUSY_THRESHOLD:.0f}% avg): CPUs {fmt_list(hot_cpus)}")
    print(f"  MID   (mixed):        CPUs {fmt_list(mid_cpus)}")
    print(f"  IDLE  (≤{IDLE_THRESHOLD:.0f}% avg):  CPUs {fmt_list(idle_cpus)}")
    if contended:
        print(f"\n  ⚠  CONTENDED (hot + high sys/irq): CPUs {fmt_list(contended)}")
        print("     These cores carry both application work and interrupt/kernel overhead.")
        print("     If any of these are your testpmd lcores, IRQ affinity is wrong.")

    # ── 3. Timeseries of top-N busiest cores ────────────────────────────────
    top_n = sorted_cpus[:min(TOP_N_TIMESERIES, num_cpus)]

    subhdr(f"3. Per-second timeseries — top {len(top_n)} busiest CPUs")

    # Build timestamp → cpu → total mapping
    ts_order = []
    ts_data  = defaultdict(dict)  # ts → cpu → total
    for s in samples:
        if s["cpu"] in top_n:
            ts_key = s["ts"]
            if ts_key not in ts_data:
                ts_order.append(ts_key)
            ts_data[ts_key][s["cpu"]] = s["total"]

    # De-duplicate timestamps while preserving order
    seen = set()
    ts_order_dedup = []
    for t in ts_order:
        if t not in seen:
            ts_order_dedup.append(t)
            seen.add(t)

    # Print header
    header_parts = ["Time        "] + [f"CPU{c:>3}" for c in top_n]
    print("  " + "  ".join(header_parts))
    print("  " + SEP)

    for ts in ts_order_dedup:
        row = [ts]
        for cpu in top_n:
            v = ts_data[ts].get(cpu)
            row.append(f"{v:6.1f}" if v is not None else "   n/a")
        print("  " + "  ".join(row))

    # ── 4. Recommendations ──────────────────────────────────────────────────
    subhdr("4. Recommendations")

    issues = []

    # Check: expected testpmd cores busy?
    if not hot_cpus:
        issues.append((
            "WARN",
            "No core reached the hot threshold (%.0f%%)." % BUSY_THRESHOLD,
            "testpmd may not have been running, or the experiment duration was too short."
        ))

    # Check: contention on hot cores
    for cpu in contended:
        s = cpu_stats[cpu]
        detail = (f"CPU {cpu}: avg_sys={s['avg_sys']:.1f}% "
                  f"avg_irq={s['avg_irq']:.1f}%")
        issues.append((
            "ERROR",
            f"CPU {cpu} is hot but has high sys/irq overhead — likely IRQ affinity problem.",
            f"{detail}. "
            f"Set /proc/irq/*/smp_affinity to keep IRQs off testpmd lcores."
        ))

    # Check: mid-level cores (might be vhost/OVS cores leaking in)
    if mid_cpus:
        issues.append((
            "INFO",
            f"CPUs {fmt_list(mid_cpus)} are at medium utilization (5–70%).",
            "These may be kernel vhost workers, OVS PMDs, or background tasks. "
            "Verify with 'ps -eLo pid,psr,comm | grep kthread' during the experiment."
        ))

    # Check: testpmd on one core while others are idle
    if len(hot_cpus) == 1 and len(idle_cpus) >= 2:
        issues.append((
            "WARN",
            f"Only 1 hot core (CPU {hot_cpus[0]}) with {len(idle_cpus)} idle cores.",
            "testpmd is bottlenecked on 1 core. "
            "Increase --nb-cores and add lcores in launch_testpmd.sh."
        ))

    # Check: all cores idle — maybe the experiment window was missed
    if len(idle_cpus) == num_cpus:
        issues.append((
            "WARN",
            "All CPUs were idle throughout the capture.",
            "The experiment may not have run while the monitor was active, "
            "or traffic was not flowing."
        ))

    # Stability: high stddev on hot cores
    for cpu in hot_cpus:
        s = cpu_stats[cpu]
        if s["std_total"] > 20.0:
            issues.append((
                "WARN",
                f"CPU {cpu} utilization is unstable (stddev={s['std_total']:.1f}%).",
                "Erratic utilization can indicate lock contention, scheduler migration, "
                "or burst/drain behaviour in the AF_XDP rings."
            ))

    if not issues:
        print("  ✓ No obvious CPU configuration problems detected.")
    else:
        for level, summary, detail in issues:
            icon = {"ERROR": "✗", "WARN": "⚠", "INFO": "ℹ"}.get(level, "·")
            print(f"\n  {icon} [{level}] {summary}")
            print(f"         → {detail}")

    print(f"\n{'═' * W}\n")

# ── entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: python3 {sys.argv[0]} <cpu_monitor_*.log>")
        sys.exit(1)
    analyze(sys.argv[1])
