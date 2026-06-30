# Harvester / Longhorn v2 SPDK CPU Affinity and Workqueue Lockup Case Summary

Generated: 2026-06-29 08:03:02

## 1. Case Summary

A Harvester node running Longhorn v2 / SPDK shows repeated Linux kernel workqueue lockup warnings on CPUs used by SPDK reactors.

The most important finding is:

```text
SPDK is using CPU2 and CPU3 via --spdk-cpumask 0xC.
The same CPUs still receive normal Linux kernel work, softirqs, NIC IRQs, storage IRQs, and workqueue tasks.
The kernel workqueue lockups occur on the same CPUs, especially CPU3.
```

This suggests a CPU isolation / affinity mismatch rather than a single subsystem issue such as only `nf_conntrack` or only `mgag200`.

## 2. Relevant Kernel Logs

### 2.1 Workqueue lockup on CPU3

Latest example:

```text
Jun 29 07:35:26 harvester-node-1 kernel: BUG: workqueue lockup - pool cpus=3 node=0 flags=0x0 nice=0 stuck for 649s!
Jun 29 07:35:26 harvester-node-1 kernel: Showing busy workqueues and worker pools:
Jun 29 07:35:26 harvester-node-1 kernel: workqueue events: flags=0x0
Jun 29 07:35:26 harvester-node-1 kernel:   pwq 14: cpus=3 node=0 flags=0x0 nice=0 active=1 refcnt=2
Jun 29 07:35:26 harvester-node-1 kernel:     in-flight: 2990528:output_poll_execute
Jun 29 07:35:26 harvester-node-1 kernel: workqueue events_power_efficient: flags=0x80
Jun 29 07:35:26 harvester-node-1 kernel:   pwq 14: cpus=3 node=0 flags=0x0 nice=0 active=1 refcnt=2
Jun 29 07:35:26 harvester-node-1 kernel:     pending: gc_worker [nf_conntrack]
Jun 29 07:35:26 harvester-node-1 kernel: workqueue mm_percpu_wq: flags=0x8
Jun 29 07:35:26 harvester-node-1 kernel:   pwq 14: cpus=3 node=0 flags=0x0 nice=0 active=1 refcnt=2
Jun 29 07:35:26 harvester-node-1 kernel:     pending: vmstat_update
Jun 29 07:35:26 harvester-node-1 kernel: pool 14: cpus=3 node=0 flags=0x0 nice=0 hung=649s workers=2 idle: 2721593
Jun 29 07:35:26 harvester-node-1 kernel: task:kworker/3:1     state:R  running task     stack:0     pid:2990528
Jun 29 07:35:26 harvester-node-1 kernel: Workqueue: events output_poll_execute
```

### 2.2 Call trace

The call trace points to DRM display output polling through the BMC VGA / `mgag200` path:

```text
output_poll_execute
drm_helper_probe_detect_ctx
mgag200_vga_bmc_connector_helper_detect_ctx
drm_connector_helper_detect_from_ddc
drm_probe_ddc
drm_do_probe_ddc_edid
i2c_transfer
bit_xfer
try_address [i2c_algo_bit]
```

Interpretation:

```text
The active blocked worker is kworker/3:1, PID 2990528.
It is running DRM output polling, trying to probe DDC/EDID via mgag200/i2c.
nf_conntrack GC is only pending behind the same CPU3 worker pool, not the active blocker in this latest log.
```

## 3. Important Evidence From Host

### 3.1 SPDK CPU mask

The instance manager starts SPDK with:

```text
--spdk-cpumask 0xC
spdk_tgt -L all -m 0xC --mem-size 2048
```

`0xC` is binary `1100`, which means:

```text
CPU2 + CPU3
```

### 3.2 SPDK reactors are pinned and busy

From the host process/thread output:

```text
2749088 2749088   2  TS  - 19 0 RLl 99.9 reactor_2  spdk_tgt -L all -m 0xC --mem-size 2048
2749088 2749125   3  TS  - 19 0 RLl 99.9 reactor_3  spdk_tgt -L all -m 0xC --mem-size 2048
```

Interpretation:

```text
reactor_2 is pinned to CPU2 and consumes ~99.9% CPU.
reactor_3 is pinned to CPU3 and consumes ~99.9% CPU.
Both are SCHED_OTHER, not SCHED_FIFO/SCHED_RR.
```

This rules out real-time scheduling starvation, but CPU2/CPU3 are still saturated by SPDK poll-mode reactors.

### 3.3 Same PID appears in both kernel log and ps output

Kernel log:

```text
task:kworker/3:1 pid:2990528
Workqueue: events output_poll_execute
```

Process output:

```text
2990528 2990528 3 TS - 19 0 R 0.0 - kworker/3:1+events [kworker/3:1+events]
```

Interpretation:

```text
The kernel log and host process output refer to the same stuck worker: PID 2990528, kworker/3:1, running on CPU3.
```

### 3.4 No CPU isolation boot parameters are currently active

Current kernel command line:

```text
BOOT_IMAGE=(loop0)/boot/vmlinuz console=tty1 root=LABEL=COS_STATE cos-img/filename=/cOS/active.img panic=0 net.ifnames=1 rd.cos.oemlabel=COS_OEM rd.cos.mount=LABEL=COS_OEM:/oem rd.cos.mount=LABEL=COS_PERSISTENT:/usr/local rd.cos.oemtimeout=120 audit=1 audit_backlog_limit=8192 intel_iommu=on amd_iommu=on iommu=pt multipath=off
```

Not present:

```text
irqaffinity=...
isolcpus=...
nohz_full=...
rcu_nocbs=...
drm_kms_helper.poll=0
```

### 3.5 Workqueue cpumask allows all CPUs

Current value:

```text
/sys/devices/virtual/workqueue/cpumask = ffffff
```

On a 24-CPU node, this means:

```text
CPUs 0-23
```

So unbound workqueues are allowed to run on CPU2/CPU3.

### 3.6 IRQs still land on CPU2/CPU3

Examples from `/proc/interrupts` and IRQ affinity:

```text
IRQ=109 configured=0-5,12-17 effective=2  eno49-TxRx-5
IRQ=110 configured=0-5,12-17 effective=3  eno49-TxRx-6
IRQ=121 configured=0-5,12-17 effective=2  eno49-TxRx-17
IRQ=122 configured=0-5,12-17 effective=3  eno49-TxRx-18
IRQ=135 configured=0-5,12-17 effective=2  eno50-TxRx-5
IRQ=136 configured=0-5,12-17 effective=3  eno50-TxRx-6
IRQ=69  configured=2          effective=2  hpsa0-msix14
IRQ=70  configured=3          effective=3  hpsa0-msix15
IRQ=94  configured=2          effective=2  nvme0q15
IRQ=95  configured=3          effective=3  nvme0q16
```

Important high-volume example:

```text
109: 0 5 82285883 0 ... IR-PCI-MSIX-0000:04:00.0 5-edge eno49-TxRx-5
```

Assuming the columns are CPU0, CPU1, CPU2, CPU3, ..., this means `eno49-TxRx-5` has delivered about 82 million interrupts to CPU2.

## 4. Diagnosis

### 4.1 Root finding

The node is configured like this:

```text
CPU2: SPDK reactor_2, 99.9% CPU
CPU3: SPDK reactor_3, 99.9% CPU
```

But CPU2/CPU3 are also still used for:

```text
NIC MSI-X IRQs, especially eno49/eno50 TxRx queues
storage IRQs, hpsa and nvme
ksoftirqd/2 and ksoftirqd/3
bound per-CPU kworkers
unbound workqueues, because workqueue cpumask is ffffff
DRM output polling through mgag200/i2c/DDC/EDID
```

So the SPDK CPUs are not isolated.

### 4.2 Why this can produce workqueue lockups

SPDK poll-mode reactors normally keep their CPU busy polling for I/O. Even though the reactors are `SCHED_OTHER`, they still consume almost all runtime on CPU2/CPU3.

When normal kernel work lands on those same CPUs, it competes with SPDK and device interrupt/softirq activity. If one workqueue task becomes slow or blocked, such as `output_poll_execute` in the `mgag200` DDC/EDID path, the per-CPU worker pool can be reported as locked up:

```text
BUG: workqueue lockup - pool cpus=3
```

### 4.3 Why this is probably not only nf_conntrack

Earlier logs showed `nf_conntrack gc_worker` as in-flight on CPU2. The latest CPU3 log shows `nf_conntrack gc_worker` only as pending, while the active worker is DRM output polling.

Therefore, the common factor is not only conntrack. The common factor is:

```text
The affected workqueue pools are on CPUs used by SPDK reactors.
```

## 5. Diagnostic Scripts

### 5.1 check-spdk.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== SPDK/reactor/kworker scheduling ==="
ps -eLo pid,tid,psr,cls,rtprio,pri,ni,stat,pcpu,comm,args | \
  awk 'NR==1 || /spdk|reactor|kworker\/[23][^0-9]|ksoftirqd\/[23][^0-9]/'

echo
echo "=== SPDK thread policies from chrt ==="
pid="$(pgrep -f 'spdk_tgt' | head -n1 || true)"
if [ -n "${pid}" ]; then
  for t in /proc/${pid}/task/*; do
    tid="${t##*/}"
    printf "\nTID=%s COMM=%s\n" "${tid}" "$(cat "${t}/comm")"
    chrt -p "${tid}" 2>/dev/null || true
    taskset -cp "${tid}" 2>/dev/null || true
  done
else
  echo "spdk_tgt not found"
fi
```

### 5.2 check-irq.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

for irqdir in /proc/irq/[0-9]*; do
  irq="$(basename "${irqdir}")"
  eff="$(cat "${irqdir}/effective_affinity_list" 2>/dev/null || true)"
  conf="$(cat "${irqdir}/smp_affinity_list" 2>/dev/null || true)"

  if echo "${eff}" | grep -Eq '(^|,|-)2($|,|-)|(^|,|-)3($|,|-)'; then
    echo "IRQ=${irq} configured=${conf} effective=${eff}"
    grep -w "^ *${irq}:" /proc/interrupts 2>/dev/null || true
  fi
done
```

### 5.3 check-cpu-irq-workqueue.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== cmdline ==="
cat /proc/cmdline

echo
echo "=== workqueue cpumask ==="
cat /sys/devices/virtual/workqueue/cpumask 2>/dev/null || true

echo
echo "=== SPDK/kworker placement ==="
ps -eLo pid,tid,psr,cls,rtprio,pri,ni,stat,pcpu,wchan:30,comm,args | \
  egrep 'spdk|reactor|kworker/[23][^0-9]|ksoftirqd/[23][^0-9]'

echo
echo "=== IRQs still on CPU2/3 ==="
for irqdir in /proc/irq/[0-9]*; do
  irq="$(basename "${irqdir}")"
  eff="$(cat "${irqdir}/effective_affinity_list" 2>/dev/null || true)"
  conf="$(cat "${irqdir}/smp_affinity_list" 2>/dev/null || true)"

  if echo "${eff}" | grep -Eq '(^|,|-)2($|,|-)|(^|,|-)3($|,|-)'; then
    echo "IRQ=${irq} configured=${conf} effective=${eff}"
    grep -w "^ *${irq}:" /proc/interrupts 2>/dev/null || true
  fi
done
```

## 6. Runtime Mitigation Test

For a 24-CPU node where SPDK uses CPU2/CPU3, the intended split is:

```text
SPDK CPUs:         2-3
Housekeeping CPUs: 0-1,4-23
```

Runtime test:

```bash
# Stop irqbalance for clean testing, otherwise it may move IRQs back.
systemctl stop irqbalance 2>/dev/null || true

# Future IRQ default affinity: CPUs 0-1,4-23.
# For 24 CPUs, this mask is fffff3.
echo fffff3 > /proc/irq/default_smp_affinity

# Existing IRQs: move away from CPU2/CPU3 where allowed.
for irqdir in /proc/irq/[0-9]*; do
  [ -w "${irqdir}/smp_affinity_list" ] || continue
  echo 0-1,4-23 > "${irqdir}/smp_affinity_list" 2>/dev/null || true
done

# Unbound workqueues: avoid CPU2/CPU3.
echo 0-1,4-23 > /sys/devices/virtual/workqueue/cpumask 2>/dev/null || true

# Disable DRM output polling noise on headless server nodes.
echo N > /sys/module/drm_kms_helper/parameters/poll 2>/dev/null || true
```

Then rerun:

```bash
./check-cpu-irq-workqueue.sh
```

Expected result:

```text
workqueue cpumask should no longer be ffffff.
High-volume eno49/eno50 IRQs should no longer have effective=2 or effective=3.
DRM output polling should stop recurring if drm_kms_helper.poll accepts N.
```

## 7. Persistent Mitigation Direction

If SPDK must use CPU2/CPU3, consider aligning boot-time CPU isolation:

```text
irqaffinity=0-1,4-23 isolcpus=managed_irq,domain,2-3 nohz_full=2-3 rcu_nocbs=2-3 drm_kms_helper.poll=0
```

Notes:

```text
irqaffinity=0-1,4-23
  Sets the default IRQ affinity away from SPDK CPUs.

isolcpus=managed_irq,domain,2-3
  Helps keep managed IRQs and scheduler domains away from SPDK CPUs.

nohz_full=2-3
  Reduces scheduler tick noise on SPDK CPUs.

rcu_nocbs=2-3
  Offloads RCU callbacks from SPDK CPUs.

drm_kms_helper.poll=0
  Disables DRM connector polling, useful because the latest lockup is in output_poll_execute via mgag200/DDC/EDID.
```

This should be tested on one node first.

## 8. Important Caveats

### 8.1 Some IRQs may not move at runtime

If an IRQ remains:

```text
configured=2 effective=2
```

or:

```text
configured=3 effective=3
```

after writing a new affinity list, it may be managed or constrained by the driver/IRQ core.

Examples from this case:

```text
hpsa0-msix14 effective=2
hpsa0-msix15 effective=3
nvme0q15 effective=2
nvme0q16 effective=3
```

If these are managed or driver-restricted, runtime changes may not be enough.

### 8.2 workqueue cpumask only affects unbound workqueues

Changing:

```text
/sys/devices/virtual/workqueue/cpumask
```

does not eliminate all `kworker/2` or `kworker/3` tasks, because bound per-CPU workqueues can still exist.

The latest lockup is a bound CPU3 worker pool:

```text
pool cpus=3
kworker/3:1
```

### 8.3 irqaffinity alone is not enough

The lockup is a workqueue problem, not only an IRQ problem.

IRQ tuning reduces interference, but the active stuck task is:

```text
kworker/3:1 -> output_poll_execute -> mgag200/i2c/DDC/EDID
```

So the mitigation should include both:

```text
IRQ isolation
workqueue cpumask tuning
DRM polling disablement
SPDK CPU mask / CPU placement review
```

## 9. Suggested Bug Report Summary

```text
The affected Harvester node runs Longhorn v2/SPDK with --spdk-cpumask 0xC, so SPDK reactors are pinned to CPU2 and CPU3. Both reactor_2 and reactor_3 are SCHED_OTHER but continuously consume around 99.9% CPU in poll mode.

The kernel reports workqueue lockups on the same CPUs used by SPDK. On harvester-node-1, pool cpus=3 is stuck, and the in-flight worker is kworker/3:1, PID 2990528, running Workqueue: events output_poll_execute. The call trace enters DRM/mgag200 DDC/EDID probing via i2c_algo_bit. In the same worker pool, nf_conntrack gc_worker and vmstat_update are pending.

Host diagnostics show that CPU2/CPU3 are not isolated. /proc/cmdline does not include irqaffinity, isolcpus, nohz_full, rcu_nocbs, or drm_kms_helper.poll=0. /sys/devices/virtual/workqueue/cpumask is ffffff, allowing unbound workqueues on all CPUs. High-volume NIC IRQs such as eno49-TxRx-5 and eno49-TxRx-6 are effectively assigned to CPU2/CPU3, and storage IRQs such as hpsa0-msix14/15 and nvme0q15/16 are also effective on CPU2/CPU3.

This suggests the issue is likely caused by CPU isolation/affinity mismatch: SPDK poll-mode CPUs are still handling normal kernel work, device interrupts, softirqs, and DRM polling. irqaffinity alone is insufficient; mitigation should coordinate SPDK CPU mask, IRQ affinity, unbound workqueue cpumask, managed IRQ handling, and disabling DRM connector polling on headless nodes.
```

## 10. Appendix: Latest Diagnostic Output

```text
harvester-node-1:/home/rancher # ./check-cpu-irq-workqueue.sh 
=== cmdline ===
BOOT_IMAGE=(loop0)/boot/vmlinuz console=tty1 root=LABEL=COS_STATE cos-img/filename=/cOS/active.img panic=0 net.ifnames=1 rd.cos.oemlabel=COS_OEM rd.cos.mount=LABEL=COS_OEM:/oem rd.cos.mount=LABEL=COS_PERSISTENT:/usr/local rd.cos.oemtimeout=120 audit=1 audit_backlog_limit=8192 intel_iommu=on amd_iommu=on iommu=pt multipath=off
=== workqueue cpumask ===
ffffff
=== SPDK/kworker placement ===
     33      33   2  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/2     [ksoftirqd/2]
     39      39   3  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/3     [ksoftirqd/3]
    142     142  20  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/20    [ksoftirqd/20]
    144     144  20  TS      -  39 -20 I<    0.0 worker_thread                  kworker/20:0H-e [kworker/20:0H-events_highpri]
    148     148  21  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/21    [ksoftirqd/21]
    154     154  22  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/22    [ksoftirqd/22]
    156     156  22  TS      -  39 -20 I<    0.0 worker_thread                  kworker/22:0H-e [kworker/22:0H-events_highpri]
    160     160  23  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/23    [ksoftirqd/23]
  26974   26974   3  TS      -  39 -20 I<    0.0 worker_thread                  kworker/3:2H    [kworker/3:2H]
 183406  183406   2  TS      -  39 -20 I<    0.0 worker_thread                  kworker/2:1H-nv [kworker/2:1H-nvme_tcp_wq]
 236850  236850   2  TS      -  19   0 I     0.0 worker_thread                  kworker/2:14-mm [kworker/2:14-mm_percpu_wq]
 745396  745396   3  TS      -  39 -20 I<    0.0 worker_thread                  kworker/3:0H-nv [kworker/3:0H-nvme_tcp_wq]
1144313 1144313  22  TS      -  19   0 I     0.0 worker_thread                  kworker/22:1-mm [kworker/22:1-mm_percpu_wq]
1440041 1440041   2  TS      -  39 -20 I<    0.0 worker_thread                  kworker/2:2H-nv [kworker/2:2H-nvme_tcp_wq]
2493165 2493165  21  TS      -  19   0 I     0.0 worker_thread                  kworker/21:0-ev [kworker/21:0-events]
2549611 2549611   2  TS      -  19   0 I     0.0 worker_thread                  kworker/2:19-ev [kworker/2:19-events_freezable]
2721593 2721593   3  TS      -  19   0 I     0.0 worker_thread                  kworker/3:2-eve [kworker/3:2-events]
2734561 2734561  20  TS      -  19   0 I     0.0 worker_thread                  kworker/20:2-ev [kworker/20:2-events]
2749060 2749060   8  TS      -  19   0 Ss    0.0 do_sigtimedwait.isra.0         tini            /tini -- instance-manager --spdk-log all --spdk-cpumask 0xC --spdk-memory-size 2048 --enable-spdk --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749078 2749078  16  TS      -  19   0 S     0.0 do_wait                        instance-manage /bin/bash /usr/local/bin/instance-manager --spdk-log all --spdk-cpumask 0xC --spdk-memory-size 2048 --enable-spdk --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749088 2749088   2  TS      -  19   0 RLl  99.9 -                              reactor_2       spdk_tgt -L all -m 0xC --mem-size 2048
2749088 2749091  16  TS      -  19   0 SLl   0.0 do_epoll_wait                  dpdk-intr       spdk_tgt -L all -m 0xC --mem-size 2048
2749088 2749125   3  TS      -  19   0 RLl  99.9 -                              reactor_3       spdk_tgt -L all -m 0xC --mem-size 2048
2749089 2749089  12  TS      -  19   0 S     0.0 pipe_read                      tee             tee -a /log/spdk_tgt.log
2749147 2749147  17  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749150   8  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749151  22  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749152   8  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749153  22  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749154  12  TS      -  19   0 Sl    0.0 do_epoll_wait                  longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749155  10  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749156   4  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749157  23  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749158  10  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749159  15  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749160  22  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749162   4  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749320  15  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749321   6  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749322  17  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749661   1  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749662   5  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2752329   9  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2752330  22  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2755997  19  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2775645   0  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2850227  13  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2858946  15  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 3199534   5  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 1607910  10  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2753203   8  TS      -  19   0 Sl    0.1 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2949253  14  TS      -  19   0 Sl    0.2 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2758492 2758492  23  TS      -  19   0 I     0.0 worker_thread                  kworker/23:1-ev [kworker/23:1-events]
2762677 2762677  21  TS      -  39 -20 I<    0.0 worker_thread                  kworker/21:2H   [kworker/21:2H]
2764462 2764462  22  TS      -  39 -20 I<    0.0 worker_thread                  kworker/22:2H-n [kworker/22:2H-nvme_tcp_wq]
2764469 2764469  23  TS      -  39 -20 I<    0.0 worker_thread                  kworker/23:2H-n [kworker/23:2H-nvme_tcp_wq]
2923205 2923205  21  TS      -  19   0 I     0.0 worker_thread                  kworker/21:2-cg [kworker/21:2-cgroup_destroy]
2990528 2990528   3  TS      -  19   0 R     0.0 -                              kworker/3:1+eve [kworker/3:1+events]
3078843 3078843  20  TS      -  39 -20 I<    0.0 worker_thread                  kworker/20:1H-n [kworker/20:1H-nvme_tcp_wq]
3125903 3125903  20  TS      -  19   0 I     0.0 worker_thread                  kworker/20:0    [kworker/20:0]
3229012 3229012  21  TS      -  39 -20 I<    0.0 worker_thread                  kworker/21:1H-k [kworker/21:1H-kblockd]
3259422 3259422  22  TS      -  19   0 I     0.0 worker_thread                  kworker/22:0    [kworker/22:0]
3280383 3280383  23  TS      -  39 -20 I<    0.0 worker_thread                  kworker/23:0H-k [kworker/23:0H-kblockd]
3437890 3437890  23  TS      -  19   0 I     0.0 worker_thread                  kworker/23:0    [kworker/23:0]
3461766 3461766   9  TS      -  19   0 S+    0.0 pipe_read                      grep            grep -E spdk|reactor|kworker/2|kworker/3|ksoftirqd/2|ksoftirqd/3
=== IRQs still on CPU2/3 ===
IRQ=109 configured=0-5,12-17 effective=2
 109:          0          5   82285883          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:04:00.0    5-edge      eno49-TxRx-5
IRQ=110 configured=0-5,12-17 effective=3
 110:          0          0          5   61009427          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:04:00.0    6-edge      eno49-TxRx-6
IRQ=121 configured=0-5,12-17 effective=2
 121:          0          5   20690866          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:04:00.0   17-edge      eno49-TxRx-17
IRQ=122 configured=0-5,12-17 effective=3
 122:          0          0          5   20633600          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:04:00.0   18-edge      eno49-TxRx-18
IRQ=135 configured=0-5,12-17 effective=2
 135:          0          0     430970          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:04:00.1    5-edge      eno50-TxRx-5
IRQ=136 configured=0-5,12-17 effective=3
 136:          0          0          0     430970          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:04:00.1    6-edge      eno50-TxRx-6
IRQ=147 configured=0-5,12-17 effective=2
 147:          0          0     430970          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:04:00.1   17-edge      eno50-TxRx-17
IRQ=148 configured=0-5,12-17 effective=3
 148:          0          0          0     430970          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:04:00.1   18-edge      eno50-TxRx-18
IRQ=159 configured=0-5,12-17 effective=2
 159:          0          0          2          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:00:04.2    0-edge      ioat-msix
IRQ=160 configured=0-5,12-17 effective=3
 160:          0          0          0          2          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:00:04.3    0-edge      ioat-msix
IRQ=24 configured=0-23 effective=2
  24:          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  DMAR-MSI    0-edge      dmar0
IRQ=25 configured=0-23 effective=3
  25:          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  DMAR-MSI    1-edge      dmar1
IRQ=39 configured=0-5,12-17 effective=2
  39:          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSI-0000:00:1c.0    0-edge      PCIe PME
IRQ=40 configured=0-5,12-17 effective=3
  40:          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSI-0000:00:1c.2    0-edge      PCIe PME
IRQ=69 configured=2 effective=2
  69:          0          0    2038792          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:03:00.0   14-edge      hpsa0-msix14
IRQ=70 configured=3 effective=3
  70:          0          0          0    2056006          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:03:00.0   15-edge      hpsa0-msix15
IRQ=94 configured=2 effective=2
  94:          0          0       2378          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:05:00.0   15-edge      nvme0q15
IRQ=95 configured=3 effective=3
  95:          0          0          0       2413          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0          0  IR-PCI-MSIX-0000:05:00.0   16-edge      nvme0q16
```

## 11. Appendix: Previous Host Detail Output

```text
harvester-node-1:/home/rancher # pgrep -af 'spdk_tgt|instance-manager'
16202 /tini -- instance-manager --debug daemon --listen :8500
16235 longhorn-instance-manager --debug daemon --listen :8500
2749060 /tini -- instance-manager --spdk-log all --spdk-cpumask 0xC --spdk-memory-size 2048 --enable-spdk --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749078 /bin/bash /usr/local/bin/instance-manager --spdk-log all --spdk-cpumask 0xC --spdk-memory-size 2048 --enable-spdk --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749088 spdk_tgt -L all -m 0xC --mem-size 2048
2749089 tee -a /log/spdk_tgt.log
2749147 longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749149 tee -a /log/instance-manager-v2.log
4023485 longhorn-manager -d daemon --engine-image docker.io/longhornio/longhorn-engine:v1.12.0 --instance-manager-image docker.io/longhornio/longhorn-instance-manager:v1.12.0 --share-manager-image docker.io/longhornio/longhorn-share-manager:v1.12.0 --backing-image-manager-image docker.io/longhornio/backing-image-manager:v1.12.0 --support-bundle-manager-image docker.io/longhornio/support-bundle-kit:v0.0.86 --manager-image docker.io/longhornio/longhorn-manager:v1.12.0 --service-account longhorn-service-account
harvester-node-1:/home/rancher # ps -eLo pid,tid,psr,cls,rtprio,pri,ni,stat,pcpu,wchan:30,comm,args | \
>   egrep 'spdk|reactor|kworker/2|kworker/3|ksoftirqd/2|ksoftirqd/3'
     33      33   2  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/2     [ksoftirqd/2]
     39      39   3  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/3     [ksoftirqd/3]
    142     142  20  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/20    [ksoftirqd/20]
    144     144  20  TS      -  39 -20 I<    0.0 worker_thread                  kworker/20:0H-e [kworker/20:0H-events_highpri]
    148     148  21  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/21    [ksoftirqd/21]
    154     154  22  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/22    [ksoftirqd/22]
    156     156  22  TS      -  39 -20 I<    0.0 worker_thread                  kworker/22:0H-e [kworker/22:0H-events_highpri]
    160     160  23  TS      -  19   0 S     0.0 smpboot_thread_fn              ksoftirqd/23    [ksoftirqd/23]
  26974   26974   3  TS      -  39 -20 I<    0.0 worker_thread                  kworker/3:2H    [kworker/3:2H]
 183406  183406   2  TS      -  39 -20 I<    0.0 worker_thread                  kworker/2:1H-nv [kworker/2:1H-nvme_tcp_wq]
 236850  236850   2  TS      -  19   0 I     0.0 worker_thread                  kworker/2:14-mm [kworker/2:14-mm_percpu_wq]
 745396  745396   3  TS      -  39 -20 I<    0.0 worker_thread                  kworker/3:0H-nv [kworker/3:0H-nvme_tcp_wq]
1144313 1144313  22  TS      -  19   0 I     0.0 worker_thread                  kworker/22:1-mm [kworker/22:1-mm_percpu_wq]
1440041 1440041   2  TS      -  39 -20 I<    0.0 worker_thread                  kworker/2:2H-nv [kworker/2:2H-nvme_tcp_wq]
1965757 1965757  23  TS      -  19   0 I     0.0 worker_thread                  kworker/23:3-mm [kworker/23:3-mm_percpu_wq]
2493165 2493165  21  TS      -  19   0 I     0.0 worker_thread                  kworker/21:0-mm [kworker/21:0-mm_percpu_wq]
2549611 2549611   2  TS      -  19   0 I     0.0 worker_thread                  kworker/2:19-ev [kworker/2:19-events_freezable]
2721593 2721593   3  TS      -  19   0 I     0.0 worker_thread                  kworker/3:2-eve [kworker/3:2-events]
2734561 2734561  20  TS      -  19   0 I     0.0 worker_thread                  kworker/20:2-mm [kworker/20:2-mm_percpu_wq]
2749060 2749060  20  TS      -  19   0 Ss    0.0 do_sigtimedwait.isra.0         tini            /tini -- instance-manager --spdk-log all --spdk-cpumask 0xC --spdk-memory-size 2048 --enable-spdk --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749078 2749078  16  TS      -  19   0 S     0.0 do_wait                        instance-manage /bin/bash /usr/local/bin/instance-manager --spdk-log all --spdk-cpumask 0xC --spdk-memory-size 2048 --enable-spdk --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749088 2749088   2  TS      -  19   0 RLl  99.9 -                              reactor_2       spdk_tgt -L all -m 0xC --mem-size 2048
2749088 2749091  16  TS      -  19   0 SLl   0.0 do_epoll_wait                  dpdk-intr       spdk_tgt -L all -m 0xC --mem-size 2048
2749088 2749125   3  TS      -  19   0 RLl  99.9 -                              reactor_3       spdk_tgt -L all -m 0xC --mem-size 2048
2749089 2749089  12  TS      -  19   0 S     0.0 pipe_read                      tee             tee -a /log/spdk_tgt.log
2749147 2749147  17  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749150  10  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749151  22  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749152  16  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749153  22  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749154  19  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749155  15  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749156   4  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749157  20  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749158   1  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749159   5  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749160  13  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749162  16  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749320   5  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749321  23  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749322   0  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749661  10  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2749662  21  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2752329   1  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2752330  18  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2755997   5  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2775645   7  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2850227  17  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2858946   8  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 3199534   0  TS      -  19   0 Sl    0.0 do_epoll_wait                  longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 1607910  13  TS      -  19   0 Sl    0.0 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2753203   4  TS      -  19   0 Sl    0.1 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2749147 2949253  15  TS      -  19   0 Sl    0.2 futex_wait_queue               longhorn-instan longhorn-instance-manager --debug daemon --spdk-enabled --listen 0.0.0.0:8500
2758492 2758492  23  TS      -  19   0 I     0.0 worker_thread                  kworker/23:1    [kworker/23:1]
2762677 2762677  21  TS      -  39 -20 I<    0.0 worker_thread                  kworker/21:2H   [kworker/21:2H]
2764462 2764462  22  TS      -  39 -20 I<    0.0 worker_thread                  kworker/22:2H-k [kworker/22:2H-kblockd]
2764469 2764469  23  TS      -  39 -20 I<    0.0 worker_thread                  kworker/23:2H-n [kworker/23:2H-nvme_tcp_wq]
2923205 2923205  21  TS      -  19   0 I     0.0 worker_thread                  kworker/21:2-cg [kworker/21:2-cgroup_destroy]
2990528 2990528   3  TS      -  19   0 R     0.0 -                              kworker/3:1+eve [kworker/3:1+events_power_efficient]
3078843 3078843  20  TS      -  39 -20 I<    0.0 worker_thread                  kworker/20:1H-n [kworker/20:1H-nvme_tcp_wq]
3125903 3125903  20  TS      -  19   0 I     0.0 worker_thread                  kworker/20:0    [kworker/20:0]
3229012 3229012  21  TS      -  39 -20 I<    0.0 worker_thread                  kworker/21:1H-k [kworker/21:1H-kblockd]
3259422 3259422  22  TS      -  19   0 I     0.0 worker_thread                  kworker/22:0    [kworker/22:0]
3280383 3280383  23  TS      -  39 -20 I<    0.0 worker_thread                  kworker/23:0H-k [kworker/23:0H-kblockd]
3401784 3401784  11  TS      -  19   0 S+    0.0 pipe_read                      grep            grep --color=auto -E --color=auto spdk|reactor|kworker/2|kworker/3|ksoftirqd/2|ksoftirqd/3
```
