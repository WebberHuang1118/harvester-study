# 🧩 Harvester Node “sync stuck” Incident — Full Debug & RCA (with exact commands)

This document contains:

✔ Full problem summary
✔ All commands used during debugging
✔ Precise explanation of what each command does
✔ Root cause analysis
✔ Recovery instructions
✔ Recommendations for the future

---

# 📌 Summary of the Failure

A Harvester node fell into a **kernel-level I/O deadlock**, where:

* `sync` hung forever in `sync_bdevs`
* a `blkid` process inside **harvester-node-disk-manager** got stuck
* the node-disk-manager pod stayed in **Terminating** for >22 hours
* kubelet, containerd, and user processes could not kill it
* device I/O was frozen due to a stuck page lock
* only a **reboot** recovered the node

The root cause was a **block device flush deadlock** inside the kernel, triggered while `blkid` was scanning a problematic disk.

---

# 🚨 Symptoms & Detection

## 1. Check processes stuck in D state (uninterruptible sleep)

```
ps -eo pid,stat,comm,wchan:32 | grep D
```

or specifically for sync:

```
ps -eo pid,stat,comm,wchan:32 | grep sync
```

Output showed:

```
7631  D  sync  sync_bdevs
28310 D  sync  sync_bdevs
36947 D  sync  sync_bdevs
```

All waiting in `sync_bdevs`.

---

## 2. Check recent kernel NFS or storage errors

```
dmesg --ctime | grep -E 'nfs|error|I/O|block|reset|abort'
```

We saw:

```
nfs: server 10.115.1.8 not responding, timed out
```

---

## 3. Check NFS mounts (none active)

```
mount | grep nfs
cat /proc/mounts | grep nfs
findmnt -t nfs,nfs4
```

Nothing referenced `10.115.1.8`.

---

## 4. Force kernel to print blocked tasks (sysrq-w)

```
echo w > /proc/sysrq-trigger
dmesg | tail -n 100
```

This printed kernel stacks showing:

* `sync` stuck in `sync_bdevs`
* `blkid` stuck in `blkdev_get_by_dev`

Example:

```
sync_bdevs
__mutex_lock
```

---

## 5. Check all block devices

```
lsblk -o NAME,TYPE,SIZE,MOUNTPOINT,MODEL
```

Your node showed:

* `/` on loop0
* Longhorn NBD devices
* NVMe partitions

---

## 6. Try to identify who holds block-device locks

```
lsof | grep -E '/dev/(sd|dm-|loop|nbd|nvme)'
```

Output: nothing
Meaning the lock holder is kernel-only.

---

## 7. Inspect systemd-udevd (common offender)

```
for p in $(pidof systemd-udevd); do
  echo "PID $p"
  cat /proc/$p/stack
done
```

udev was idle in epoll → not the culprit.

---

## 8. Deep scan for *any* process doing block-device operations

Create script:

```
cat > find-holder.sh << 'EOF'
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  if grep -q blkdev /proc/$pid/stack 2>/dev/null; then
    echo "PID $pid is doing block device operations"
    cat /proc/$pid/stack
  fi
done
EOF
chmod +x find-holder.sh
```

Run it:

```
./find-holder.sh
```

### 🔥 Output (critical):

```
PID 11034 is doing block device operations
__lock_page
truncate_inode_pages_range
blkdev_flush_mapping
blkdev_put
blkdev_close
__fput
do_exit
```

This tells us PID **11034** is stuck while **closing** a block device.

---

# 🕵️ Identifying PID 11034

Check the process:

```
ps -p 11034 -o pid,ppid,cmd
```

You found:

```
node-disk-manager → blkid
```

Process tree:

```
containerd-shim
 └─ node-disk-manager
      └─ blkid (PID 11034)   <-- stuck
```

This meant:

* `harvester-node-disk-manager` pod started blkid
* blkid scanned a device that hung
* blkid is stuck in kernel `do_exit`
* containerd-shim cannot exit
* pod stuck **Terminating**

---

# 🧱 Why killing blkid doesn’t work

Check FD list:

```
ls -l /proc/11034/fd
```

Check if any block device is still referenced:

```
readlink -f /proc/11034/fd/* 2>/dev/null | grep '^/dev/'
```

No block devices remain because blkid **already closed the FD**, and got stuck in kernel cleanup.

A process stuck in kernel `D` state **cannot** be killed:

```
kill -9 11034     # no effect
```

Reason: signals are ignored in uninterruptible kernel sleep.

---

# 🚧 Why deleting the pod doesn’t work

Check pod:

```
kubectl -n harvester-system get pods | grep node-disk-manager
```

Even after running:

```
kubectl delete pod --force --grace-period=0
```

It remains in:

```
Terminating
```

Because:

* kubelet waits for containerd
* containerd waits for containerd-shim
* containerd-shim waits for all processes to exit
* blkid never exits
* → pod is impossible to delete

---

# 🧨 Root Cause Summary

Root cause:

### **blkid inside harvester-node-disk-manager tried to scan a block device whose I/O path froze.**

This caused blkid (PID 11034) to get stuck inside:

```
blkdev_close
blkdev_put
truncate_inode_pages_range
__lock_page   <-- unrecoverable wait
```

Consequences:

* blkid held the block-device lock
* `sync` and other blkid processes blocked behind it in `sync_bdevs`
* pod stuck Terminating
* containerd-shim stuck
* kubectl could not delete the pod
* node could not cleanly sync or unmount devices
* system required reboot

---

# 🔧 Final Recovery

### ✅ Only solution: **reboot the node**

After reboot:

* all D-state processes cleared
* node-disk-manager recreated normally
* block layer lock released
* sync no longer hangs

---

# 🛠 Recommended Follow-Up

### Check node-disk-manager logs (after reboot):

```
kubectl -n harvester-system logs harvester-node-disk-manager-XXXXX --previous
```

Look for:

* blkid timeouts
* I/O errors
* Longhorn nbd device issues
* missing disks
* filesystem errors

### Check for NFS or storage instability near this timestamp:

```
journalctl --since "2025-12-10 10:40"
```

Check Longhorn:

```
kubectl -n longhorn-system get pods
```

---

# 📘 Appendix: Useful Commands for Future Investigations

### Print all blocked tasks:

```
echo w > /proc/sysrq-trigger
dmesg | tail -n 200
```

### Show all D-state tasks:

```
ps -eo pid,stat,comm,wchan:32 | grep D
```

### Identify processes doing block I/O:

```
grep -R blkdev /proc/*/stack 2>/dev/null
```

### List all mounts:

```
findmnt
cat /proc/mounts
mount
```

### List devices:

```
lsblk -o NAME,TYPE,SIZE,MOUNTPOINT,MODEL
```

### Check block-layer errors:

```
dmesg | grep -E 'I/O|blk|sd[a-z]|nvme|reset|abort'
```

### Check NFS issues:

```
dmesg | grep nfs
```

---

# 🟩 Closing Note

This was a textbook case of a **kernel-level block-device deadlock**, and all debugging steps you performed were correct.
