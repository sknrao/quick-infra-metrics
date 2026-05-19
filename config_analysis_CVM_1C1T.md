# CVM 1C1T Configuration Analysis
**Log:** CVM_cpu_monitor / net_hugepage_host / net_hugepage_vm — run1  
**Host:** volcano-598f-host | AMD EPYC 9755 (2×128c, 512 threads) | Kernel 6.17.0-rc3+  
**VM:** kernel 6.17.7+ | 1C1T testpmd + AF_XDP + force_copy=1

---

## Summary of findings

| # | Severity | Location | Issue |
|---|----------|----------|-------|
| 1 | CRITICAL | VM | 96.8% XDP drop rate — XSK fill ring starvation |
| 2 | HIGH | Host | 4 OVS PMD threads configured for a 1-queue setup (only 2 needed) |
| 3 | HIGH | VM | Monitor started with testpmd already running — BASELINE is polluted |
| 4 | HIGH | VM | 1G hugepages not configured in VM; 370 MB allocated using 185×2MB pages |
| 5 | MEDIUM | Host | vhost kernel workers (CPU 305/306) at 44% sys — kick storm |
| 6 | MEDIUM | Host | OVS NIC TX queue mismatch: n_txq=1 configured but 41 TX queues active |
| 7 | LOW | Both | CPU affinity not captured in either monitor (affinity snapshots empty) |

---

## Issue 1 — CRITICAL: 96.8% XDP drop rate (fill ring starvation)

**Evidence (VM, baseline → last sample, 308s window):**

```
enp0s3:
  XDP received :   318,793,489  (1.035 Mpps avg from OVS)
  XDP redirects:   318,793,489  (100.0% — kernel redirected every packet successfully)
  XDP drops    :   308,665,350  (96.8% — dropped after redirect, fill ring empty)
  Forwarded    :    10,128,139  (3.2% actually reached testpmd)
  TX out       :     9,799,874  (0.032 Mpps)

enp0s4: identical pattern — 96.6% drop rate
```

**What this means:** `xdp_redirects = xdp_packets` (100%) means the XDP program itself is
working perfectly — every packet that arrives is redirected to the AF_XDP socket. The drops
happen *after* redirect, inside the kernel's XSK layer, because the **UMEM fill ring has no
free descriptors** when the packet arrives. testpmd is not refilling the fill ring fast enough.

**Root cause chain:**  
`force_copy=1` → every packet is memcpy'd under SEV-SNP memory encryption → single
forwarding lcore cannot drain both XSK sockets fast enough → fill ring empties →
kernel has nowhere to place incoming packets → `xdp_drops` increments.

**rx_kicks delta:** 4,865 over 308s = ~16/s. This is the number of times testpmd's
busy-poll timed out and fell back to a kernel wakeup. Very low — busy-poll is mostly
working, but the bottleneck is the copy speed, not the polling mechanism.

**Fix:** Remove `force_copy=1` from `launch_testpmd.sh`. Let DPDK attempt zero-copy
and fall back gracefully. Even if it falls back (because vhost-user PA regions aren't
contiguous), the internal DPDK UMEM-to-mbuf copy path is faster than the forced
kernel-path copy. Additionally, add `--nb-cores=2` with one lcore dedicated per port.

---

## Issue 2 — HIGH: 4 OVS PMD threads for a 1-queue topology

**Evidence (host CPU monitor):**

```
CPU24   avg_total=100%  avg_usr=100%  avg_sys=0%   — OVS PMD
CPU28   avg_total=100%  avg_usr=100%  avg_sys=0%   — OVS PMD
CPU32   avg_total=100%  avg_usr=100%  avg_sys=0%   — OVS PMD
CPU36   avg_total=100%  avg_usr=100%  avg_sys=0%   — OVS PMD
```

All 4 are in **NUMA node 0** (CPUs 0–127), same as both physical NICs (`numa_id=0`).
NUMA placement is correct, but the *count* is wrong.

**For 1C1T (1 queue per port, 4 ports total: dpdk-p0, dpdk-p1, vm01p01, vm02p01):**
- OVS assigns ports to PMDs. With 4 PMDs and 4 single-queue ports, each PMD owns ~1 port.
- Each PMD busy-polls its port continuously regardless of whether there is traffic on it.
- Two of the four PMD cores are therefore **idle-spinning** on ports that have no work to do
  in a given direction at a given moment.
- Worse: when a vhost PMD and a physical-port PMD need to hand off a packet, they must
  coordinate through a shared ring. More PMDs means more lock contention on that ring.

**For 1C1T you need exactly 2 PMD threads** — one handling `dpdk-p0 ↔ vm01p01`,
one handling `dpdk-p1 ↔ vm02p01`. The extra 2 cores (28, 36 or 24, 32) are wasted.

**Fix:**
```bash
# Set PMD mask to exactly 2 cores, e.g. CPU 24 and 28 (NUMA0, different physical cores)
ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=0x1100000
# 0x1100000 = bits 24 and 28 set
# Verify: ovs-appctl dpif-netdev/pmd-stats-show
```

Also pin each PMD to a specific port+queue using `pmd-rxq-affinity` to avoid OVS
auto-balancing moving queues between PMDs mid-run:
```bash
ovs-vsctl set Interface dpdk-p0  other_config:pmd-rxq-affinity="0:24"
ovs-vsctl set Interface vm01p01  other_config:pmd-rxq-affinity="0:24"
ovs-vsctl set Interface dpdk-p1  other_config:pmd-rxq-affinity="0:28"
ovs-vsctl set Interface vm02p01  other_config:pmd-rxq-affinity="0:28"
```

---

## Issue 3 — HIGH: Monitor baseline is polluted (testpmd pre-existing)

**Evidence (VM net_hugepage log):**

```
BASELINE timestamp: 07:11:47
  enp0s3 rx_xdp_packets : 482,257,609  ← non-zero at baseline
  enp0s3 xdp_drops      : 443,994,677  ← non-zero at baseline
  bpftool net list      : EMPTY        ← no XDP program shown
```

The baseline shows **482M packets already processed** but `bpftool` shows no XDP program
attached. This contradiction means testpmd was already running from a *prior* invocation
that was not cleanly stopped, and `bpftool` couldn't see the XDP programs because they were
attached to the AF_XDP sockets which had already been torn down and re-created by the time
the monitor started — or the XDP detach/reattach race happened within the same 2s sample.

The baseline counters include traffic from the previous run. The deltas computed from this
baseline are correct (the script subtracts correctly), but the **run itself was started on
top of stale state**. The 5 pre-existing trmap files (`trmap_1..4, trmap_9`) at baseline
confirm testpmd was not cleanly shut down between runs.

**Fix:** Add to `launch_testpmd.sh` before launching:
```bash
# Kill any stale testpmd
pkill -f dpdk-testpmd 2>/dev/null; sleep 2
# Remove stale hugepage files
rm -f /dev/hugepages/trmap_*
# Confirm clean
ls /dev/hugepages/ && echo "clean" || echo "stale files remain"
```
And always start the monitor *after* this cleanup, *before* the new testpmd launch.

---

## Issue 4 — HIGH: No 1G hugepages in VM; 185 × 2MB pages for 370MB

**Evidence:**

```
Baseline /dev/hugepages:   5 files  × 2MB = 10MB   (stale from prior run)
End      /dev/hugepages: 185 files  × 2MB = 370MB
Delta consumed:          180 files  × 2MB = 360MB

/sys per-NUMA:  hugepages-1048576kB  total=0   ← zero 1G pages
                hugepages-2048kB     total=3072  ← all 2MB
```

DPDK allocated **185 separate 2MB hugepage files** for what could be covered by **1 single
1G page**. Each 2MB page requires its own TLB entry. With 185 pages active, the DPDK
mempool walks through up to 185 TLB entries on every mbuf allocation — directly increasing
cache miss rate per packet under SEV-SNP memory encryption, where every miss is more
expensive than in a regular VM.

The AF_XDP UMEM is backed by this memory. When testpmd writes a packet descriptor into the
fill ring, the kernel must translate the UMEM virtual address to a physical address for the
NIC. With 2MB pages this requires more page-table levels than with 1G pages.

**Fix:**
```bash
# In VM: allocate 1G hugepages instead of (or in addition to) 2MB pages
echo 4 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
mkdir -p /mnt/huge1G
mount -t hugetlbfs -o pagesize=1G none /mnt/huge1G

# In launch_testpmd.sh: add --huge-dir=/mnt/huge1G
# DPDK will prefer 1G pages when available
```
4 × 1G = 4GB — more than enough for the 370MB DPDK actually needs, and it eliminates
184 TLB entries from the hot path.

---

## Issue 5 — MEDIUM: Vhost kernel workers in kick storm (CPU 305/306 at 44% sys)

**Evidence:**

```
CPU49   avg_total= 96%  avg_usr=0%  avg_sys= 1%  — vhost worker thread
CPU304  avg_total= 97%  avg_usr=0%  avg_sys= 1%  — vhost worker (sibling of CPU48)
CPU305  avg_total= 76%  avg_usr=0%  avg_sys=44%  — vhost TX completions
CPU306  avg_total= 58%  avg_usr=0%  avg_sys=43%  — vhost TX completions
```

CPUs 305 and 306 are spending 44% of their time in kernel (`sys`) with near-zero
`usr` — the hallmark of virtio/vhost interrupt and kick processing. The vhost
`tx_q0_guest_notifications` counter for vm01p01 is 20,659 and vm02p01 is 17,262 —
these are the number of times OVS had to kick the guest to notify it of new TX
descriptors. That's very low (good). But the high `sys` on 305/306 suggests the
*reverse path* — the VM's testpmd kicking the host's vhost worker to signal TX
completions — is generating significant interrupt overhead.

This is a consequence of Issue 1: because testpmd is processing only 3.2% of packets,
it's constantly completing small batches and kicking the vhost ring for each one.
Fixing Issue 1 (higher throughput, larger batches) will naturally reduce kick frequency.

Additionally, `ovs_tx_failure_drops` on vm01p01 = **11,281,063,399** and vm02p01 =
**11,523,363,878**. These are packets OVS *attempted* to send to the VM via the vhost
ring but the ring was full (testpmd's RX ring was backed up). This confirms the guest
is the bottleneck, not OVS.

---

## Issue 6 — MEDIUM: OVS NIC TX queue mismatch (n_txq=1 vs 41 active)

**Evidence (host OVS port status):**

```
dpdk-p0 status: n_txq=41  (OVS reports 41 TX queues active on the NIC)
dpdk-p1 status: n_txq=33
dpdk-p0 config: n_txq="1" (only 1 TX queue configured in OVS options)
```

OVS configured `n_txq=1` but the MLX5 driver reports 41 and 33 TX queues open. This
happens because OVS DPDK opens one TX queue *per PMD thread* by default (for lock-free
per-thread TX), regardless of the `n_txq` option (which controls RX). With 4 PMD cores
that's 4 TX queues at minimum — but the MLX5 driver may pre-allocate more.

The practical consequence: TX traffic from OVS is distributed across tx_q12 (for dpdk-p0,
visible in the stats: `tx_q12_packets=103,539,686`), while all other TX queues show 0.
This is not actively causing a loss, but it means the `n_txq=1` config is not being
honored. If you reduce to 2 PMD threads (Issue 2 fix), the number of active TX queues
will drop correspondingly and reduce NIC resource usage.

---

## Issue 7 — LOW: CPU affinity snapshots are empty in both monitors

**Evidence:**

```
=== CPU affinity snapshot at start ===
                                        ← empty
=== CPU affinity snapshot at stop ===
                                        ← empty
```

The `taskset -cp $(pgrep -f dpdk-testpmd)` in `cpu_monitor.sh` found no testpmd PID at
snapshot time (because testpmd is inside the VM, not visible from the host where the CPU
monitor runs). This is a **monitoring script design issue**, not a testpmd config issue.

The cpu_monitor.sh is running on the HOST but looking for a dpdk-testpmd process — which
only exists inside the CVM guest and is invisible from the host. You need to run
cpu_monitor.sh *inside the VM* to capture testpmd's affinity.

**Fix:** Run two cpu_monitor instances simultaneously:
- Host: captures OVS PMD affinity + vhost worker distribution  
- VM: captures testpmd lcore affinity

---

## Issue 8 (your specific question) — AF_XDP socket and queue binding

**Short answer: queue binding is correct. The problem is one layer deeper.**

**Evidence:**
- `rx0_xdp_packets` and `rx0_kicks` counters are populated (queue index 0)
- No `rx1_*` counters exist → only queue 0 is bound → consistent with `start_queue=0, queue_count=1`
- OVS vhost `n_rxq=1` → only ever delivers to virtio queue 0 → consistent
- XDP redirect success = 100% → the XSKMAP lookup for queue 0 always succeeds

The AF_XDP socket is correctly bound to queue 0 on both interfaces. The XDP program
(`xdp_redirect_xs`, id 35 and 37) correctly redirects 100% of packets to the XSK.

**The actual problem is what happens after the redirect succeeds:**

```
Packet arrives at enp0s3 queue 0
  → NIC DMA into kernel ring
  → XDP program runs: bpf_redirect_map(xskmap, 0) → XDP_REDIRECT  [always succeeds]
  → Kernel tries to place packet into UMEM fill ring
  → Fill ring is EMPTY (testpmd hasn't refilled it)
  → Packet dropped → xdp_drops++
```

The fill ring is the pool of pre-allocated UMEM frames that testpmd offers to the kernel
for the kernel to write incoming packets into. With `force_copy=1`, testpmd copies each
packet out of the UMEM into an mbuf before it can recycle the UMEM frame back to the fill
ring. At 1 Mpps arriving and ~32 Kpps actually forwarded, the recycle rate is far below
the arrival rate — the fill ring drains immediately.

---

## How to monitor AF_XDP socket state in real time (during a run)

Add this to your monitoring toolkit. Run it inside the VM while testpmd is running:

```bash
#!/bin/bash
# xsk_monitor.sh — watch AF_XDP socket ring state every 1s
# Requires: ethtool, bpftool (for map dumps)

IFACES="enp0s3 enp0s4"
INTERVAL=1

prev_xdp=(); prev_drops=(); prev_kicks=(); prev_tx_kicks=()

while true; do
    ts=$(date '+%H:%M:%S')
    printf "\n%s\n" "$ts"
    printf "%-10s %10s %10s %10s %10s %10s %10s\n" \
        "iface" "xdp_pps" "drop_pps" "drop%" "rx_kicks/s" "tx_kicks/s" "fill_starve"

    for iface in $IFACES; do
        xdp=$(ethtool -S $iface 2>/dev/null | awk '/rx_xdp_packets/{print $2}')
        drp=$(ethtool -S $iface 2>/dev/null | awk '/rx_xdp_drops/{print $2}')
        rxk=$(ethtool -S $iface 2>/dev/null | awk '/^[[:space:]]*rx_kicks/{print $2; exit}')
        txk=$(ethtool -S $iface 2>/dev/null | awk '/^[[:space:]]*tx_kicks/{print $2; exit}')

        # Compute deltas
        idx="${iface}"
        d_xdp=$((xdp - ${prev_xdp[$idx]:-$xdp}))
        d_drp=$((drp - ${prev_drops[$idx]:-$drp}))
        d_rxk=$((rxk - ${prev_kicks[$idx]:-$rxk}))
        d_txk=$((txk - ${prev_tx_kicks[$idx]:-$txk}))

        drop_pct=0
        [ "$d_xdp" -gt 0 ] && drop_pct=$((d_drp * 100 / d_xdp))

        # fill_starve: high drop% with low rx_kicks = fill ring chronically empty
        starve="NO"
        [ "$drop_pct" -gt 50 ] && [ "$d_rxk" -lt 100 ] && starve="YES ← CRITICAL"
        [ "$drop_pct" -gt 50 ] && [ "$d_rxk" -ge 100 ] && starve="KICKS"

        printf "%-10s %10d %10d %9d%% %10d %10d %10s\n" \
            "$iface" "$d_xdp" "$d_drp" "$drop_pct" "$d_rxk" "$d_txk" "$starve"

        prev_xdp[$idx]=$xdp
        prev_drops[$idx]=$drp
        prev_kicks[$idx]=$rxk
        prev_tx_kicks[$idx]=$txk
    done

    # Also show fill ring occupancy via bpftool if available
    if command -v bpftool >/dev/null 2>&1; then
        for iface in $IFACES; do
            prog_id=$(bpftool net show dev $iface 2>/dev/null | grep -oP 'id \K\d+' | head -1)
            if [ -n "$prog_id" ]; then
                map_ids=$(bpftool prog show id $prog_id 2>/dev/null | grep -oP 'map_ids \K[\d,]+')
                for mid in $(echo $map_ids | tr ',' ' '); do
                    mtype=$(bpftool map show id $mid 2>/dev/null | grep -oP 'type \K\S+')
                    if [ "$mtype" = "xskmap" ]; then
                        printf "  XSK map id=%s entries:\n" "$mid"
                        bpftool map dump id $mid 2>/dev/null | head -5
                    fi
                done
            fi
        done
    fi

    sleep $INTERVAL
done
```

**What each column tells you:**

| Column | Meaning | What to look for |
|--------|---------|-----------------|
| `xdp_pps` | Packets/s arriving from NIC to XDP | Should match Xena TX rate |
| `drop_pps` | Packets/s dropped after XDP redirect | Should be near 0 |
| `drop%` | Drop rate this interval | >5% = fill ring problem |
| `rx_kicks/s` | Times testpmd woke up kernel to receive | High = busy-poll not working |
| `tx_kicks/s` | Times testpmd kicked kernel for TX | High = TX ring contention |
| `fill_starve` | YES = drop% >50% AND kicks low = fill ring chronically empty | Critical alert |

**Additional: watch /proc/PID/fdinfo for XSK ring state (requires testpmd PID inside VM):**

```bash
TPMD=$(pgrep -f dpdk-testpmd)
for fd in /proc/$TPMD/fd/*; do
    link=$(readlink $fd 2>/dev/null)
    echo "$link" | grep -q "socket" || continue
    inode=$(echo "$link" | grep -oP '\d+')
    # Check if it's an AF_XDP socket
    grep -q "$inode" /proc/net/xdp 2>/dev/null && \
        echo "XSK fd=$(basename $fd) inode=$inode:" && \
        cat /proc/$TPMD/fdinfo/$(basename $fd) 2>/dev/null
done
```

`/proc/net/xdp` shows per-socket: `rx_dropped`, `rx_invalid`, `rx_full`,
`fill_ring_empty` — `fill_ring_empty` directly counts the fill starvation events.

---

## Recommended fix sequence

1. **Inside VM — clean start:**  
   `pkill dpdk-testpmd; rm -f /dev/hugepages/trmap_*; sleep 2`

2. **Inside VM — enable 1G hugepages:**  
   `echo 4 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages`  
   Add `--huge-dir=/mnt/huge1G` to testpmd args

3. **Launch testpmd — remove force_copy, add a second lcore:**  
   Change `force_copy=1` → remove entirely  
   Change `--nb-cores=1` → `--nb-cores=2`, add one more lcore to `-l`

4. **On host — reduce OVS PMD count to 2:**  
   `ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=0x1100000`  
   Pin queues with `pmd-rxq-affinity`

5. **Run cpu_monitor inside VM** (not host) to capture testpmd lcore affinity

6. **During test — run xsk_monitor.sh** to watch fill ring health in real time
