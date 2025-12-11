# Harvester Longhorn CSI Node Staging Path Troubleshooting Guide (Block Mode)

## Context

Harvester uses **Longhorn in Block mode (RWO)** to attach disks to VMs. Each volume is managed via the CSI node staging path:

```
/var/lib/kubelet/plugins/kubernetes.io/csi/pv/<pv-name>/staging
```

If the Longhorn CSI driver fails during `NodeStageVolume` or `NodeUnstageVolume`, the staging path can become **stale** or **stuck**, blocking the VM (virt-launcher pod) from starting.

---

## Symptoms

* VM stuck in **Starting** or **Scheduling** state.
* `virt-launcher` pod logs show:

  * `MountVolume.Setup failed for volume... device busy`
  * `timeout waiting for mount`
  * `no such device`
* Longhorn volume appears **Attached** in the UI, but kubelet fails to proceed.

---

## Step 0 — Identify the PV

```bash
kubectl get pvc -A | grep <vm-name>
kubectl get pv | grep <pvc-name>
PV=<pv-name>
```

Staging path:

```bash
/var/lib/kubelet/plugins/kubernetes.io/csi/pv/$PV/staging
```

---

## Step 1 — Determine if Stale or Stuck

Run these on the **Harvester node** hosting the VM:

### 1. Check mount state

```bash
findmnt -R /var/lib/kubelet/plugins/kubernetes.io/csi/pv/$PV/staging
```

### 2. Check if Longhorn device exists

```bash
ls -l /dev/longhorn/
```

If `/dev/longhorn/<volume>` is **missing**, but findmnt shows it mounted → **STALE**.

### 3. Check CSI volumeDevices and loop devices (Block Mode)

For block mode volumes, also check the CSI volumeDevices paths and loop device bindings:

```bash
# Check loop devices
losetup

# Find CSI volumeDevices for your PVC
ls -l /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/pvc-*

# Check mount points for volumeDevices
mount | grep pvc-<pvc-name>

# Check detailed mount info
grep pvc-<pvc-name> /proc/self/mountinfo

# Use findmnt to check recursive mounts
findmnt -R /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/staging/pvc-<pvc-name>
```

**Example from real environment:**

```bash
# Loop devices show the volume device binding
hp-155-tink-system:/home/rancher # losetup 
NAME SIZELIMIT OFFSET AUTOCLEAR RO BACK-FILE                                                                                                      DIO LOG-SEC
/dev/loop2
             0      0         0  0 /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/pvc-b2d2ffba-b735-41ed-a611-ed3614742036/dev/1b4895fe-bd55-4307-ad92-7bc1cdc74464
                                                                                                                                                    0     512

# The device file exists as a block device
hp-155-tink-system:/home/rancher # ls -al /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/pvc-b2d2ffba-b735-41ed-a611-ed3614742036/dev/1b4895fe-bd55-4307-ad92-7bc1cdc74464
brw-rw---- 1 root 6 8, 32 Oct 14 10:53 /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/pvc-b2d2ffba-b735-41ed-a611-ed3614742036/dev/1b4895fe-bd55-4307-ad92-7bc1cdc74464

# Mount points show devtmpfs bindings
hp-155-tink-system:/home/rancher # mount | grep pvc-b2d2ffba-b735-41ed-a611-ed3614742036
devtmpfs on /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/staging/pvc-b2d2ffba-b735-41ed-a611-ed3614742036/pvc-b2d2ffba-b735-41ed-a611-ed3614742036 type devtmpfs (rw,size=4096k,nr_inodes=1048576,mode=755,inode64)
devtmpfs on /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/publish/pvc-b2d2ffba-b735-41ed-a611-ed3614742036/1b4895fe-bd55-4307-ad92-7bc1cdc74464 type devtmpfs (rw,size=4096k,nr_inodes=1048576,mode=755,inode64)
devtmpfs on /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/pvc-b2d2ffba-b735-41ed-a611-ed3614742036/dev/1b4895fe-bd55-4307-ad92-7bc1cdc74464 type devtmpfs (rw,size=4096k,nr_inodes=1048576,mode=755,inode64)

# Detailed mount info shows the actual Longhorn volume path
hp-155-tink-system:/home/rancher # grep pvc-b2d2ffba-b735-41ed-a611-ed3614742036 /proc/self/mountinfo 
4941 183 0:5 /longhorn/pvc-b2d2ffba-b735-41ed-a611-ed3614742036 /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/staging/pvc-b2d2ffba-b735-41ed-a611-ed3614742036/pvc-b2d2ffba-b735-41ed-a611-ed3614742036 rw shared:1294 - devtmpfs devtmpfs rw,size=4096k,nr_inodes=1048576,mode=755,inode64
4956 183 0:5 /longhorn/pvc-b2d2ffba-b735-41ed-a611-ed3614742036 /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/publish/pvc-b2d2ffba-b735-41ed-a611-ed3614742036/1b4895fe-bd55-4307-ad92-7bc1cdc74464 rw shared:1294 - devtmpfs devtmpfs rw,size=4096k,nr_inodes=1048576,mode=755,inode64
4969 183 0:5 /longhorn/pvc-b2d2ffba-b735-41ed-a611-ed3614742036 /var/lib/kubelet/plugins/kubernetes.io/csi/volumeDevices/pvc-b2d2ffba-b735-41ed-a611-ed3614742036/dev/1b4895fe-bd55-4307-ad92-7bc1cdc74464 rw shared:1294 - devtmpfs devtmpfs rw,size=4096k,nr_inodes=1048576,mode=755,inode64
```

**Signs of issues with volumeDevices:**
- Loop device shows in `losetup` but accessing the device fails with "No such device"
- Multiple devtmpfs mount points for the same PVC (staging, publish, dev paths)
- Block device file exists but is inaccessible
- Mount info shows `/longhorn/pvc-*` path but actual `/dev/longhorn/` device is missing

### 4. Try normal unmount

```bash
umount /var/lib/kubelet/plugins/kubernetes.io/csi/pv/$PV/staging
```

If `target is busy` or it hangs → **STUCK**.

### 5. Find holders

```bash
lsof +f -- /var/lib/kubelet/plugins/kubernetes.io/csi/pv/$PV/staging
fuser -vm /var/lib/kubelet/plugins/kubernetes.io/csi/pv/$PV/staging
```

* If processes appear → STUCK.
* If none, but mount persists → STALE.

### 6. Detect kubelet rebinds

```bash
grep "$PV" /proc/self/mountinfo
```

If both staging and pod paths exist → kubelet rebind loop → stop kubelet before cleanup.

---

## Step 2 — Clean It Safely

### 1. Stop kubelet

```bash
systemctl stop kubelet
```

### 2. Unmount recursively (lazy if needed)

```bash
findmnt -Rno TARGET /var/lib/kubelet/plugins/kubernetes.io/csi/pv/$PV | tac | xargs -r umount || \
findmnt -Rno TARGET /var/lib/kubelet/plugins/kubernetes.io/csi/pv/$PV | tac | xargs -r umount -l
```

### 3. Verify

```bash
findmnt -T /var/lib/kubelet/plugins/kubernetes.io/csi/pv/$PV/staging || echo "Unmounted"
mountpoint -q /var/lib/kubelet/plugins/kubernetes.io/csi/pv/$PV/staging || echo "Path is free"
```

### 4. Remove leftover dir

```bash
rm -rf /var/lib/kubelet/plugins/kubernetes.io/csi/pv/$PV/staging
```

### 5. Restart kubelet

```bash
systemctl start kubelet
```

---

## Step 3 — Confirm Volume and Restart VM

Check that Longhorn reattached the block device:

```bash
ls /dev/longhorn/ | grep <volume>
```

If not found:

```bash
kubectl -n longhorn-system get lv,le,lim,lep | grep <volume>
```

Ensure the volume and engine are attached to the same node as the VM pod.

Restart the VM:

```bash
virtctl restart <vm-name>
```

Or delete virt-launcher:

```bash
kubectl delete pod -n <ns> -l kubevirt.io=virt-launcher,vm.kubevirt.io/name=<vm-name>
```

---

## Step 4 — Quick Classification Summary

| Symptom                                                  | Meaning              | Fix                                                |
| -------------------------------------------------------- | -------------------- | -------------------------------------------------- |
| `/dev/longhorn/<vol>` missing but staging mounted        | **STALE**            | Stop kubelet → `umount -l` → start kubelet         |
| `umount` says busy or hangs; kubelet/containerd hold FDs | **STUCK**            | Stop kubelet → `umount -R` or `-l` → start kubelet |
| Duplicate mountinfo entries                              | **Kubelet loop**     | Stop kubelet, unmount, restart kubelet             |
| I/O errors or missing device in dmesg                    | **Detached mid-I/O** | Lazy unmount, restart kubelet                      |

---

## ⚡ Why It Happens

### 1️⃣ Kubelet or CSI restarted mid-operation

During NodeStageVolume or NodeUnstageVolume, kubelet or the Longhorn CSI node pod restarts, leaving a half-mounted path.

### 2️⃣ Longhorn engine detached unexpectedly

Longhorn engine crashed, lost network to replicas, or force-detached → device gone but mount persists.

### 3️⃣ Force detach or node timeout

Force detach removes device while still mounted, causing kernel-level stale reference.

### 4️⃣ **Etcd instability or API unavailability**

When etcd is slow, partitioned, or unavailable, the Kubernetes control plane and Longhorn become desynchronized:

* **Lost VolumeAttachment updates:** Kubelet attaches device but etcd write fails → control plane reattaches → duplicate mount.
* **Missed NodeUnstageVolume:** Kubelet cannot send RPC when VM stops → CSI never unmounts staging → stale path.
* **Desynced state:** Longhorn detaches while kubelet still believes volume is staged → `/dev/longhorn/<vol>` disappears while mounted.

➡️ **Result:** stale or stuck node staging paths requiring manual unmount.

### 5️⃣ Kernel I/O or D-state lock

Engine crash mid-I/O causes uninterruptible mount (D-state) — only lazy unmount works.

### 6️⃣ Node reboot during cleanup

If kubelet reboots mid-unmount, the mount entry persists but device disappears.

---

## 🩺 Summary Table

| Cause                         | Description                    | Result               |
| ----------------------------- | ------------------------------ | -------------------- |
| CSI/kubelet restart mid-mount | Operation interrupted          | Stale mount          |
| Longhorn engine crash         | Device gone while mounted      | Stale mount          |
| Force detach during I/O       | Device removed mid-use         | Stuck                |
| **Etcd instability**          | CSI calls lost or out of order | Stale or stuck mount |
| Kernel I/O hang               | Device blocked in D-state      | Stuck                |
| Node reboot mid-cleanup       | Mount persisted, device gone   | Stale mount          |

---

## ✅ TL;DR

Clean procedure when VM won’t start due to stuck staging path:

```bash
systemctl stop kubelet
findmnt -Rno TARGET /var/lib/kubelet/plugins/kubernetes.io/csi/pv/<pv> | tac | xargs -r umount -l
rm -rf /var/lib/kubelet/plugins/kubernetes.io/csi/pv/<pv>/staging
systemctl start kubelet
virtctl restart <vm>
```
