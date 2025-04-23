# Volume Online Resize

## Table of Contents
- [Environment](#environment)
- [Block Mode PVC (LH)](#block-mode-pvc-lh)
  - [Steps](#steps)
- [Filesystem Mode PVC (LH)](#filesystem-mode-pvc-lh)
  - [Steps](#steps-1)
  - [Note](#note)
- [Filesystem Mode PVC (Corner Case)](#filesystem-mode-pvc-corner-case)
  - [Example Pods](#example-pods)
  - [Solution](#solution)
    - [Mount the PVC to Another Pod](#mount-the-pvc-to-another-pod)
    - [Detach and Re-Attach the Volume](#detach-and-re-attach-the-volume)
- [Understanding the Directory Structure](#understanding-the-directory-structure)
  - [Summary](#summary)
  - [Step-by-Step Process on the Node](#step-by-step-process-on-the-node)
  - [Verifying the Behavior](#verifying-the-behavior)
  - [Using `findmnt` to Verify Bind-Mounts](#using-findmnt-to-verify-bind-mounts)
  - [Key Points](#key-points)
  - [Behavior with Multiple Hotplug Volumes](#behavior-with-multiple-hotplug-volumes)

## Environment
Harvester master commit `dc6013785a4d93f06a58cb0a230fa68fcb78d828` with PR [#7978](https://github.com/harvester/harvester/pull/7978)

## Block Mode PVC (LH)

### Steps
1. Add block mode PVC to VM as hotplug volume:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  namespace: backup
  name: lh-pvc-block
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Block
  resources:
    requests:
      storage: 10Gi
  storageClassName: 1rep
```

2. Before expand (`/dev/sda`):

```bash
$ lsblk
NAME    MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0     7:0    0  63.5M  1 loop /snap/core20/2015
loop1     7:1    0 111.9M  1 loop /snap/lxd/24322
loop2     7:2    0  89.4M  1 loop /snap/lxd/31333
loop3     7:3    0  40.8M  1 loop /snap/snapd/20092
sda       8:0    0    10G  0 disk 
vda     252:0    0     5G  0 disk 
├─vda1  252:1    0   4.9G  0 part /
├─vda14 252:14   0     4M  0 part 
└─vda15 252:15   0   106M  0 part /boot/efi
```

3. After expand (`/dev/sda`):

```bash
$ lsblk
NAME    MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0     7:0    0  63.5M  1 loop /snap/core20/2015
loop1     7:1    0 111.9M  1 loop /snap/lxd/24322
loop2     7:2    0  89.4M  1 loop /snap/lxd/31333
loop3     7:3    0  40.8M  1 loop /snap/snapd/20092
sda       8:0    0   220G  0 disk 
vda     252:0    0     5G  0 disk 
├─vda1  252:1    0   4.9G  0 part /
├─vda14 252:14   0     4M  0 part 
└─vda15 252:15   0   106M  0 part /boot/efi
vdb     252:16   0     1M  0 disk
```

## Filesystem Mode PVC (LH)

### Steps
1. Add filesystem mode PVC to VM as hotplug volume:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  namespace: backup
  name: lh-pvc-fs
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: 10Gi
  storageClassName: 1rep
```

2. Before expand (`/dev/sda`) added as `/dev/vdx` ahead:

```bash
$ lsblk
NAME    MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0     7:0    0  63.5M  1 loop /snap/core20/2015
loop1     7:1    0 111.9M  1 loop /snap/lxd/24322
loop2     7:2    0  89.4M  1 loop /snap/lxd/31333
loop3     7:3    0  40.8M  1 loop /snap/snapd/20092
sda       8:0    0  18.9G  0 disk 
vda     252:0    0     5G  0 disk 
├─vda1  252:1    0   4.9G  0 part /
├─vda14 252:14   0     4M  0 part 
└─vda15 252:15   0   106M  0 part /boot/efi
vdb     252:16   0     1M  0 disk
```

3. After expand (`/dev/sda`):

```bash
$ lsblk
NAME    MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0     7:0    0  63.5M  1 loop /snap/core20/2015
loop1     7:1    0 111.9M  1 loop /snap/lxd/24322
loop2     7:2    0  89.4M  1 loop /snap/lxd/31333
loop3     7:3    0  40.8M  1 loop /snap/snapd/20092
sda       8:0    0  28.3G  0 disk 
vda     252:0    0     5G  0 disk 
├─vda1  252:1    0   4.9G  0 part /
├─vda14 252:14   0     4M  0 part 
└─vda15 252:15   0   106M  0 part /boot/efi
vdb     252:16   0     1M  0 disk
```

### Note
Check the mount point in the hotplug pod to find a disk image file:

```bash
$ ls -al /lh-pvc-fs/
total 28
drwxrwsr-x 3 root qemu        4096 Apr 18 08:36 .
drwxr-xr-x 1 root root        4096 Apr 18 08:36 ..
-rw-r--r-- 1 qemu qemu 30440161280 Apr 18 08:37 disk.img
drwxrws--- 2 root qemu       16384 Apr 18 08:15 lost+found
```

### Filesystem Mode PVC (Corner Case)

**TL;DR:** This corner case occurs when:
1. A filesystem mode PVC is hotplugged to a running VM.
2. The PVC is not the latest one to be hotplugged to the running VM.
3. After the PVC is hotplugged, the VM does not experience a reboot.

A corner case exists for filesystem mode PVCs (e.g., `lh-pvc-fs-rwx.yaml`). If the PVC is a hotplug volume for a VM and is not the most recently hotplugged volume, it will not be expanded. This issue occurs because the CSI `NodeExpand()` function is not invoked, as the PVC is not mounted to either the `virt-launcher` pod or the `hotplug` pod. For instance, consider a PVC named `lh-pvc-fs-rwx`.

**Note:** If the VM undergoes a reboot before the expansion, this corner case will not occur because all PVCs will be mounted in the `hp-volume` pod.

#### Example Pods

**Virt-launcher pod:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: virt-launcher-vm1-5p9zp
  namespace: default
spec:
  hostname: vm1
  nodeName: harvester-node-0
  volumes:
  - emptyDir: {}
    name: private
  - emptyDir: {}
    name: public
  - emptyDir: {}
    name: sockets
  - emptyDir: {}
    name: virt-bin-share-dir
  - emptyDir: {}
    name: libvirt-runtime
  - emptyDir: {}
    name: ephemeral-disks
  - emptyDir: {}
    name: container-disks
  - name: disk-1
    persistentVolumeClaim:
      claimName: os-vol
  - name: cloudinitdisk-udata
    secret:
      defaultMode: 420
      secretName: vm1-fwgsm
  - name: cloudinitdisk-ndata
    secret:
      defaultMode: 420
      secretName: vm1-fwgsm
  - emptyDir: {}
    name: hotplug-disks
```

**Hotplug volume pod:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hp-volume-29rxw
  namespace: default
spec:
  volumes:
  - emptyDir: {}
    name: hotplug-disks
  - name: lh-pvc-fs-rwx
    persistentVolumeClaim:
      claimName: lh-pvc-fs-rwx
  - name: lh-v2-pvc
    persistentVolumeClaim:
      claimName: lh-v2-pvc
```

### Solution

To ensure the CSI `NodeExpand()` function is triggered for PVC expansion, follow these steps:

#### Mount the PVC to Another Pod

The PVC must be mounted to another pod with ReadWriteMany (RWX) access mode. Below is an example pod configuration (`lh-pvc-fs-rwx-pod.yaml`) to achieve this:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: lh-pvc-fs-rwx-pod
spec:
  containers:
  - name: volume-test
    image: ubuntu
    imagePullPolicy: IfNotPresent
    securityContext:
      privileged: true
    command: ["/bin/sleep"]
    args: ["3600"]
    volumeMounts:
    - mountPath: /lh-pvc-fs-rwx
      name: lh-pvc-fs-rwx
  volumes:
  - name: lh-pvc-fs-rwx
    persistentVolumeClaim:
      claimName: lh-pvc-fs-rwx
```

Once this pod is created, the PVC will be expanded, triggering the CSI `NodeExpand()` function. This ensures the expansion propagates to the VM.

#### Detach and Re-Attach the Volume

Alternatively, you can detach and re-attach the volume to the VM using the following commands:

1. Detach the volume from the VM:
   ```bash
   virtctl removevolume vm1 --volume-name lh-pvc-fs-rwx
   ```

2. Re-attach the volume to the VM:
   ```bash
   virtctl addvolume vm1 --volume-name lh-pvc-fs-rwx
   ```

## Understanding the Directory Structure

### Summary
The EmptyDir volumes used by the `virt-launcher` and `hp-volume` pods are **not shared**. Instead, KubeVirt uses a **host-level bind-mount** to link the image file (or block device) from the `hp-volume` pod’s CSI mount into the `virt-launcher` pod’s EmptyDir. This ensures the disk is visible inside `virt-launcher` without the two EmptyDirs being directly connected.

### Step-by-Step Process on the Node

1. **hp-volume Pod Initialization**
   - The kubelet calls `NodePublishVolume`, mounting the PVC under the CSI pod-mount path:
     ```
     /var/lib/kubelet/pods/<hp-volume-UID>/volumes/kubernetes.io~csi/<pvc-uid>/mount/
     └─ disk.img  # Created by virt-handler
     ```
   - The `hp-volume` pod’s container does not use this file, so it is not visible under `/path`.

2. **virt-handler Detects the Hotplug Volume**
   - The `mountFileSystemHotplugVolume()` function (in `pkg/virt-handler/hotplug-disk/mount.go`) locates the CSI pod-mount path, creates `disk.img` if missing, and executes:
     ```bash
     mount --bind <hp-pod-mount>/disk.img \
                  <virt-launcher-EmptyDir>/topolvm-fs-pvc.img
     ```
   - This places the file inside the `virt-launcher` EmptyDir:
     ```
     /var/lib/kubelet/pods/<virt-launcher-UID>/volumes/kubernetes.io~empty-dir/hotplug-disks/
     └─ topolvm-fs-pvc.img  # Bind-mount of the CSI pod-mount
     ```

3. **Immediate Visibility in virt-launcher**
   - The `virt-launcher` EmptyDir is mounted with `mountPropagation: HostToContainer`. This ensures any host-side mounts under the directory are instantly visible inside the container.

4. **hp-volume Pod’s EmptyDir is Independent**
   - The `/path` in the `hp-volume` pod is its own EmptyDir, unrelated to the `virt-launcher` EmptyDir. No bind-mounts are added under it, so `ls /path` only shows files specific to the `hp-volume` pod.

### Verifying the Behavior

To confirm this setup on the node (or via `crictl exec` into `virt-handler`):

1. Check the file created by `virt-handler`:
   ```bash
   ls -l /var/lib/kubelet/pods/<hp-UID>/volumes/kubernetes.io~csi/<pvc-uid>/mount/disk.img
   ```

2. Verify the bind-mount into the `virt-launcher` EmptyDir:
   ```bash
   findmnt -no SOURCE,TARGET /var/lib/kubelet/pods/<virt-UID>/volumes/kubernetes.io~empty-dir/hotplug-disks/topolvm-fs-pvc.img
   ```
   - `SOURCE` should point to the CSI pod-mount path.
   - `TARGET` should point to the `virt-launcher` EmptyDir.

### Using `findmnt` to Verify Bind-Mounts

The `findmnt` command is a powerful tool to inspect and verify the bind-mounts created by KubeVirt for hot-plugged volumes. Below is an example of how to use `findmnt` effectively:

#### Example Output
```bash
findmnt -no SOURCE,TARGET /var/lib/kubelet/pods/<virt-UID>/volumes/kubernetes.io~empty-dir/hotplug-disks/topolvm-fs-pvc.img
```
Output:
```
SOURCE                                                      TARGET
/dev/mapper/myvg1-2979d232…[/disk.img]                     /var/lib/…/hotplug-disks/topolvm-fs-pvc.img
```

#### How to Interpret the Output
| Field | Description |
|-------|-------------|
| **`/dev/mapper/myvg1-2979d232…`** | The **block device** (an LVM logical volume in the TopoLVM volume group) holding the PVC’s filesystem. |
| **`[/disk.img]`** | Indicates a **file-level bind mount**, where the root is the single file `disk.img` located at the PVC’s mount point. |
| **TARGET path** | The location where the kernel has mounted the file, visible to the `virt-launcher` pod. |

#### Key Insights
- The `disk.img` file on the logical volume is bind-mounted into the `virt-launcher` pod’s EmptyDir, enabling the guest to see the new block device.
- The `hp-volume` pod’s EmptyDir is not involved in this process; the bind-mount is directly managed by `virt-handler` on the host.
- The `[ /disk.img ]` notation confirms a single-file bind mount, showing the kernel’s mapping of the file to the target path.

#### Verification Steps
1. Run the `findmnt` command to inspect the bind-mount:
   ```bash
   findmnt -no SOURCE,TARGET /var/lib/kubelet/pods/<virt-UID>/volumes/kubernetes.io~empty-dir/hotplug-disks/topolvm-fs-pvc.img
   ```
2. Confirm that the `SOURCE` points to the PVC’s logical volume and the `TARGET` points to the `virt-launcher` pod’s EmptyDir.

### Key Points

- **EmptyDir Volumes are Per-Pod**: Each pod has its own EmptyDir volume, which is not shared with other pods.
- **Host-Level Bind-Mount**: KubeVirt manually bind-mounts the relevant file (or device) from the `hp-volume` pod’s CSI mount into the `virt-launcher` pod’s EmptyDir.
- **Mount Propagation**: The `HostToContainer` propagation ensures the disk is visible inside `virt-launcher` immediately after the bind-mount.

### Behavior with Multiple Hotplug Volumes

If a second volume is hot-plugged into the VM, the old `hp-volume` pod will be replaced by the new one. The new `hp-volume` pod is only responsible for handling the `NodeStage()` and `NodePublish()` operations for the second volume. Consequently, the first hotplugged volume will undergo `NodeUnPublish()` and `NodeUnstage()` operations. However, the image file for the first volume remains bind-mounted in the `virt-launcher` pod.

This behavior explains why the online expansion for the first volume is not completed. Since the first volume is no longer managed by the `hp-volume` pod, the necessary CSI operations to propagate the size expansion (e.g., `NodeExpand()`) are not triggered. As a result, the VM will not see the volume size expansion for the first hotplugged volume.