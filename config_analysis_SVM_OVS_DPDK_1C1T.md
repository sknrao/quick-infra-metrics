# Configuration Analysis: SEV-SNP VM + OVS-DPDK + AF-XDP Testpmd
### Run: `SVM_1c1t_turbo_off_2M_run1` — May 18 2026

---

## 1. Test Environment Summary

| Parameter | Value |
|---|---|
| **Host** | `volcano-5913-host` |
| **Host Kernel** | `6.17.0-rc3+` |
| **VM Kernel** | `6.17.7+` |
| **VM Name** | `Ubuntu24-without-encryption2` |
| **CPU** | AMD EPYC 9755 (Turin) — 2 sockets × 128 cores × 2 HT = 512 logical CPUs |
| **CPU Frequency** | 2.7 GHz (turbo **disabled**) |
| **NUMA** | 2 nodes — node0: CPUs 0-127, 256-383 / node1: CPUs 128-255, 384-511 |
| **Host memory/node** | ~1.5 TB each |
| **Virtualization** | SEV-SNP enabled (confidential VM) |
| **Host dataplane** | **OVS-DPDK** (`ovs_version: 3.3.0`, `dpdk 22.11.5 mlx5_pci`) |
| **NICs** | 2× Mellanox ConnectX (vendor `15b3`, device `1021`) — `enp241s0f0np0` / `enp241s0f1np1` |
| **Traffic generator** | Xena (back-to-back, 2 interfaces) |
| **VM dataplane** | AF-XDP + testpmd (`1C 1T` — 1 core, 1 queue per port) |
| **vhost type** | `dpdkvhostuserclient` (OVS as client, VM as server) |
| **Test duration** | ~10 min (09:34 → 09:44 UTC) |

---

## 2. Plumbing / Connectivity Verification

### ✅ Traffic is flowing end-to-end

The data path is **correctly wired**: Xena → NIC → OVS-DPDK → vhost-user → VM (AF-XDP testpmd) → vhost-user → OVS-DPDK → NIC → Xena.

Evidence:

| Check Point | Observation | Status |
|---|---|---|
| OVS bridge `br0` has correct ports | `dpdk-p0`, `dpdk-p1`, `vm01p01`, `vm02p01` | ✅ |
| Physical ports receiving frames | dpdk-p0 RX: ~2.8B pkts / dpdk-p1 RX: ~2.8B pkts | ✅ |
| Vhost ports receiving from VM | vm01p01 RX: ~41.5M pkts / vm02p01 RX: ~41.8M pkts | ✅ |
| VM interfaces up with PROMISC | `enp0s9`, `enp0s10` both `UP,PROMISC` | ✅ |
| XDP program active on VM ifaces | `rx_xdp_packets` counter incrementing | ✅ |
| XDP redirect rate | **~100%** (XDP is correctly redirecting to AF-XDP socket) | ✅ |
| VM hugepages allocated by testpmd | 185 × 2M pages = 370 MB consumed and stable | ✅ |
| Host hugepages for OVS-DPDK | 4 × 1G pages = 4 GB consumed and stable | ✅ |

**Verdict: The plumbing is correct. There is no configuration/wiring error.**

---

## 3. Host CPU Analysis

### 3.1 Active CPUs during the run

The following CPUs showed significant activity (averaged over 603 1-second samples):

| Host CPU | NUMA | avg %usr | avg %sys | avg %guest | avg %idle | Role |
|---|---|---|---|---|---|---|
| 280 | **node0** | 99.6 | 0.4 | 0.0 | 0.0 | OVS-DPDK PMD (poll) |
| 290 | **node0** | 97.4 | 2.6 | 0.0 | 0.0 | OVS-DPDK PMD (poll) |
| 299 | **node0** | 99.6 | 0.3 | 0.0 | 0.0 | OVS-DPDK PMD (poll) |
| 303 | **node0** | 97.5 | 2.5 | 0.0 | 0.0 | OVS-DPDK PMD (poll) |
| 180 | node1 | 0.1 | 21.5 | 62.8 | 7.2 | KVM vCPU thread (VM core) |
| 177 | node1 | 0.2 | 3.5 | 71.9 | 17.0 | KVM vCPU thread (VM core) |
| 433 | node1 | 0.2 | 19.9 | 15.4 | 59.4 | HT sibling of CPU 177 |
| 434 | node1 | 0.1 | 3.2 | 41.3 | 49.2 | HT sibling of CPU 178 |
| 432 | node1 | 0.4 | 7.6 | 6.2 | 78.1 | KVM/vhost auxiliary |
| 178 | node1 | 0.1 | 8.1 | 6.9 | 79.7 | KVM vCPU / vhost |

### 3.2 ⚠️ CRITICAL: OVS-DPDK PMDs are on the WRONG NUMA node

The NICs (`enp241s0f0np0`, `enp241s0f1np1`) report **`numa_id=1`** in the OVS port status. However, all four OVS-DPDK PMD threads are running on **NUMA node 0** (CPUs 256-383):

```
NIC NUMA:   node1
PMD CPUs:   280, 290, 299, 303  →  all on node0  ← MISMATCH
```

This means every packet traverses the inter-socket interconnect:
- DMA write by NIC (node1 memory) → PMD CPU reads (node0 cache miss → node1 fetch)
- Inter-NUMA latency on AMD Turin: ~32 hops vs ~10 local
- Expected throughput penalty: **20–50% reduction** depending on packet rate and size

**This is the single most impactful tuning gap in the host configuration.**

### 3.3 VM vCPU placement

The VM vCPU threads land on **NUMA node1** (CPUs 177, 178, 180), which is the **correct** NUMA for the NICs. The VM side is well-placed; the host OVS side is not.

### 3.4 HT sibling contention

CPUs 177 and 433 share a physical core (node1, core 49). CPU 177 runs the KVM vCPU at ~72% guest, while sibling 433 is at ~15% guest. Similarly 178/434. This indicates the VM's vCPU threads are **sharing physical cores with their own HT siblings** running KVM overhead work. For a 1C1T experiment this is unavoidable with the current pinning, but it does mean the physical core is not fully dedicated to the VM.

---

## 4. Network / OVS-DPDK Analysis

### 4.1 OVS bridge topology

```
Xena port A ──► enp241s0f0np0 (dpdk-p0, NUMA1) ──► br0 ──► vm01p01 (vhostuser) ──► VM enp0s9
Xena port B ──► enp241s0f1np1 (dpdk-p1, NUMA1) ──► br0 ──► vm02p01 (vhostuser) ──► VM enp0s10
                                                           (and symmetric return path)
```

### 4.2 Port statistics (baseline → last sample, ~10 min run)

| OVS Port | Direction | Packets | Drops | Drop Rate |
|---|---|---|---|---|
| `dpdk-p0` (phys) | RX from NIC | 2,822,242,964 | 7,096,681,940 | **71.5%** |
| `dpdk-p0` (phys) | TX to NIC | 41,461,560 | 0 | 0% ✅ |
| `dpdk-p1` (phys) | RX from NIC | 2,819,179,951 | 6,983,933,745 | **71.2%** |
| `dpdk-p1` (phys) | TX to NIC | 41,789,557 | 0 | 0% ✅ |
| `vm01p01` (vhost) | TX to VM | 1,003,639,043 | 1,818,597,184 | **64.4%** |
| `vm01p01` (vhost) | RX from VM | 41,460,456 | 0 | 0% ✅ |
| `vm02p01` (vhost) | TX to VM | 1,006,604,540 | 1,812,575,872 | **64.3%** |
| `vm02p01` (vhost) | RX from VM | 41,789,632 | 0 | 0% ✅ |

**Key observations:**

- **Physical port RX drops (~71%)**: OVS-DPDK PMD cannot drain the NIC RX ring at full line rate with only 1 RX queue and 4 PMD threads on the wrong NUMA. `rx_missed_errors` on the physical ports confirms this (3.26B on dpdk-p0, 3.35B on dpdk-p1 at the static capture point).
- **Vhost TX drops (~64%)**: OVS cannot deliver all polled packets to the VM — the vhost virtring is backed up because the VM's AF-XDP testpmd cannot consume fast enough. This is the bottleneck on the VM side.
- **Physical port TX and vhost RX are drop-free**: The return path (VM → OVS → NIC) is clean. The VM's testpmd is correctly forwarding what it receives back to OVS, and OVS is forwarding to the NIC without loss on this path.

### 4.3 ⚠️ OVS physical port RX descriptor mismatch

Both physical ports are configured with:
```
n_rxq="1", n_rxq_desc="1024"
n_txq="1", n_txq_desc="1024"
```

With a 100G NIC at line rate (~148Mpps for 64B frames), a single queue of 1024 descriptors is extremely shallow. At even 10Mpps the fill time is ~100µs. Combined with the cross-NUMA PMD placement, this results in the observed ~71% miss rate. **This is a resource constraint, not a misconfiguration** — the experiment is intentionally constrained to 1C1T.

### 4.4 OVS DPDK port options (MPRQ)

The physical ports use Multi-Packet RQ settings:
```
mprq_en=1, rxqs_min_mprq=1, mprq_log_stride_num=9, txq_inline_mpw=128, rxq_pkt_pad_en=1
```

MPRQ (Multi-Packet Receive Queue) with stride size 2^9=512B is appropriate for Mellanox CX NICs with mixed packet sizes. This is correctly configured.

### 4.5 vhost port kick rates

| Port | OVS→VM kicks (rx notifications) | VM→OVS kicks (tx notifications) | Ratio |
|---|---|---|---|
| vm01p01 | 75,163,612 | 19,503,184 | 3.85:1 |
| vm02p01 | 72,130,953 | 20,304,660 | 3.55:1 |

A **high rx kick rate** means OVS is repeatedly interrupting the VM to signal new packets. Under SEV-SNP, each VM-exit/VM-entry is significantly more expensive than on a non-CVM because:
1. The hypervisor cannot directly inspect/modify VM state
2. Additional security checks during VMRUN/VMEXIT
3. Memory encryption/decryption boundary costs

This is an inherent SEV-SNP overhead, not a misconfiguration. However, enabling **vhost event_idx** (virtqueue interrupt suppression) and batch notification can reduce the kick rate substantially.

---

## 5. VM-Side Analysis

### 5.1 AF-XDP pipeline

The VM uses AF-XDP (not native DPDK PMD) with testpmd:

| Metric | enp0s9 | enp0s10 |
|---|---|---|
| XDP total RX packets (delta) | 1,018,145,437 | ~similar |
| XDP redirects to AF-XDP socket | 1,018,056,776 | ~similar |
| XDP redirect rate | **99.99%** ✅ | **99.99%** ✅ |
| XDP drops (AF-XDP ring full) | 974,126,515 | ~similar |
| AF-XDP drop rate | **95.7%** | ~similar |

The XDP redirect rate being ~100% confirms the BPF/XDP program is **correctly redirecting all received packets to the AF-XDP UMEM**. The `rx_xdp_drops` counter does NOT mean XDP_DROP action — in the AF-XDP driver context these represent packets that were redirected but the **UMEM fill ring was not replenished in time** by testpmd. This is a back-pressure signal: testpmd's 1 core cannot replenish the fill ring at the rate packets arrive.

> **This is a resource problem (1 core cannot keep up), not an AF-XDP misconfiguration.**

### 5.2 VM hugepages

| Parameter | Value |
|---|---|
| Hugepage size | 2M (standard, no 1G pages in VM) |
| Total 2M pages configured | 3,072 (= 6 GB) |
| Pages free at baseline | 3,067 |
| Pages free during run (stable) | **2,887** (stable after ~09:34:18) |
| Pages consumed by testpmd | **185 pages = 370 MB** |
| DPDK files in /dev/hugepages | `trmap_1..4, trmap_9` (5 files × 2M = 10M initially mapped) |

Hugepage allocation is **stable throughout the run** — testpmd allocated its pool at startup and held it. No memory pressure observed.

**Note:** The VM uses only 2M hugepages. Since the host OVS uses 1G hugepages exclusively (no 2M pages allocated on host), the vhost-user shared memory (the virtqueue rings and packet buffers visible to OVS) operates across the encryption/decryption boundary managed by SNP. This is expected and correct for SEV-SNP with virtio.

### 5.3 VM interface flags

Both VM data interfaces carry `PROMISC` mode:
```
enp0s9:  <BROADCAST,MULTICAST,PROMISC,UP,LOWER_UP>
enp0s10: <BROADCAST,MULTICAST,PROMISC,UP,LOWER_UP>
```
This is correct for testpmd which needs promiscuous mode to receive all traffic regardless of MAC matching.

### 5.4 Packet size distribution (from OVS vhost port)

Traffic arriving at the VM from OVS covers a wide range (reflecting the Xena traffic profile):

| Size bucket | Count (vm01p01 TX to VM) | % |
|---|---|---|
| 1–64B (undersize) | 997,427,082 | 28.8% |
| 65–127B | 576,172,419 | 16.7% |
| 128–255B | 513,339,960 | 14.8% |
| 256–511B | 536,211,336 | 15.5% |
| 512–1023B | 270,815,753 | 7.8% |
| 1024–1522B | 563,507,846 | 16.3% |

The dominance of small (≤127B) packets is the harshest case for packet rate–limited pipelines. Each small packet still requires a full descriptor processing cycle. With 1C1T this directly limits achievable PPS.

---

## 6. Host Hugepage Analysis

| Parameter | Host |
|---|---|
| Hugepage size | 1G only (no 2M pages configured) |
| Total 1G pages | 256 (128 node0 + 128 node1) |
| Free 1G pages | **252 (stable throughout run)** |
| Used by OVS-DPDK | 4 pages = 4 GB |
| `/dev/hugepages` DPDK files | None (OVS uses `/mnt/huge` or direct 1G mount) |
| Hugetlbfs mounts | `/dev/hugepages` (1G), `/mnt/huge` (1G), `/dev/hugepages1G` (1G) |

Host hugepages are stable and correctly sized for OVS-DPDK. Three separate 1G mounts exist — this is redundant but harmless; OVS will use the one it was configured with at startup.

---

## 7. Findings Summary

### 7.1 Configuration / Plumbing: ✅ CORRECT

| Item | Status | Detail |
|---|---|---|
| OVS bridge topology | ✅ Correct | dpdk-p0/p1 → br0 → vm01p01/vm02p01 |
| vhost-user port type | ✅ Correct | dpdkvhostuserclient with server in VM |
| VM AF-XDP program | ✅ Working | 100% redirect rate to AF-XDP socket |
| VM hugepages | ✅ Correct | 2M pages, 370MB consumed, stable |
| Host hugepages | ✅ Correct | 4GB used by OVS-DPDK, stable |
| Traffic symmetry | ✅ Correct | Both directions flowing, return path drop-free |
| VM vCPU NUMA | ✅ Correct | vCPU threads on node1 (same as NIC) |
| IOMMU/IOTLB | ✅ Not in use | iotlb_hits/misses = 0 throughout |
| VM interface flags | ✅ Correct | PROMISC + UP on both data ports |

### 7.2 Performance Issues: Resource / Tuning

| Issue | Severity | Impact | Fix |
|---|---|---|---|
| **OVS PMD CPUs on NUMA0, NICs on NUMA1** | 🔴 High | ~20-50% throughput loss due to cross-NUMA memory access on every packet | Pin OVS PMDs to node1: `ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=<node1-mask>` |
| **1C1T resource constraint** | 🟡 Medium | By design — single core cannot sustain line rate for all packet sizes | This is the experiment design; expected to limit PPS |
| **High vhost kick rate under SEV-SNP** | 🟡 Medium | VM-exit overhead amplified by CVM security checks | Enable `event_idx` on virtqueue, tune `n_rxq_desc` up, consider `mrss=false` |
| **Single RX queue per physical port** | 🟡 Medium | 1024-descriptor ring drains too slowly at high pps | Increase `n_rxq_desc` to 4096 for this test; or add rxq per PMD |
| **Turbo disabled** | 🟠 Noted | Fixed 2.7GHz reduces per-core throughput ceiling | Intentional for reproducibility; accepted |
| **AF-XDP fill ring starvation** | 🟡 Medium | testpmd 1 core cannot replenish UMEM fill ring at full line rate | Resource constraint; consider increasing UMEM frame count |

---

## 8. What These Numbers Tell Us

The experiment **successfully confirms the full data path is functional**:

1. Xena sends → NIC receives → OVS-DPDK PMD polls → vhost delivers → VM AF-XDP redirects → testpmd processes → returns via same path.
2. The return path (VM TX → OVS → NIC TX) is **completely drop-free**, proving testpmd is correctly forwarding packets it successfully receives.
3. Drops occur at ingress (NIC→OVS and OVS→VM) because the **1C1T resource budget is insufficient to drain the line-rate input** — not because of any configuration error.

The dominant tuning gap observable in this data is the **OVS-DPDK PMD NUMA mismatch** (PMDs on node0, NICs on node1). Correcting this should improve OVS throughput measurably before any other optimization.

---

## 9. Recommended Next Steps

1. **Fix PMD NUMA pinning (highest priority)**
   ```bash
   # Find node1 CPU mask (e.g., CPUs 128-255, 384-511)
   ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=0x<node1-hex-mask>
   # Verify with:
   ovs-appctl dpif-netdev/pmd-stats-show
   ```

2. **Increase vhost descriptor ring depth**
   ```
   n_rxq_desc="4096", n_txq_desc="4096"
   ```

3. **Tune vhost kick suppression**
   - Ensure `mrss=true` is active (already set) to allow multi-buffer receive
   - Consider testpmd `--vhost-iova-mode=va` if IOVA issues arise with SNP

4. **Collect with more cores (2C2T, 4C4T)** to separate the NUMA effect from the core count effect

5. **Profile SEV-SNP VMEXIT cost** with `perf kvm stat` on the host to quantify the SNP overhead contribution vs. pure resource saturation

---

*Analysis generated from: `SVM_cpu_monitor_1c1t_turbo_off_2M_run1.log`, `SVM_net_hugepage_host_1c1t_turbo_off_2M_run1.log`, `SVM_net_hugepage_vm_1c1t_turbo_off_2M_run1.log`*
