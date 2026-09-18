# KubeVirt CBT backup and restore on Harvester

This guide uses KubeVirt changed block tracking (CBT) to take a full backup and an incremental backup of a running VM, reconstruct a disk from those backups, and boot a new VM from the reconstructed disk.

## Environment and example

- Harvester: **v1.9.0**
- Installed KubeVirt: **1.8.4-9.1** (based on upstream v1.8.4)
- Example VM: `default/vm1`, with one 10 GiB Block PVC named `vm1-disk-0-3oohb`
- Example backup storage: the `1rep` Longhorn StorageClass, with one filesystem PVC per backup
- Example VM network: `default/mgmt-vlan`

At the time of writing, the example cluster has a successful `Full` backup named `vm1-cbt-full`, a successful `Incremental` backup named `vm1-cbt-incremental-1`, and a running `vm1-restored` VM backed by `vm1-restored-disk`. Guest file contents have not been independently checked here. Use fresh backup names and PVCs if repeating the example.

`IncrementalBackup` and `UtilityVolumes` are **Alpha** feature gates in this KubeVirt version. KubeVirt's `backup.kubevirt.io/v1alpha1` API supplies backup and tracker resources, but no matching restore resource. The restore below uses `qemu-img`. Harvester's `harvesterhci.io` `VirtualMachineBackup` and `VirtualMachineRestore` resources are a separate backup system and do not consume these CBT backups.

These commands assume `kubectl` and `virtctl` already point at the intended cluster. Check the active context before making changes:

```bash
kubectl config current-context
kubectl get nodes
```

## 1. Check the VM and feature gates

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,OS:.status.nodeInfo.osImage
kubectl -n harvester-system get kubevirt kubevirt \
  -o jsonpath='{.status.observedKubeVirtVersion}{"\n"}{.spec.configuration.developerConfiguration.featureGates}{"\n"}{.spec.configuration.changedBlockTrackingLabelSelectors}{"\n"}'
kubectl -n default get vm vm1
kubectl -n default get pvc vm1-disk-0-3oohb
kubectl get storageclass 1rep vmstate-persistence
```

The KubeVirt configuration must contain both `IncrementalBackup` and `UtilityVolumes`, plus a CBT selector. The example selector matches only VMs labeled `cbt.kubevirt.io/enabled=true`.

For a **one-time trial**, if the gates and selector are absent, add them without replacing the existing feature-gate list:

```bash
kubectl -n harvester-system patch kubevirt kubevirt --type=json -p='[
  {"op":"add","path":"/spec/configuration/developerConfiguration/featureGates/-","value":"IncrementalBackup"},
  {"op":"add","path":"/spec/configuration/developerConfiguration/featureGates/-","value":"UtilityVolumes"},
  {"op":"add","path":"/spec/configuration/changedBlockTrackingLabelSelectors","value":{
    "virtualMachineLabelSelector":{"matchLabels":{"cbt.kubevirt.io/enabled":"true"}}
  }}
]'
```

Run that patch only when the gates are absent; repeated runs would add duplicate list entries. Harvester manages the KubeVirt resource through Helm, so persist the same settings in the deployed Harvester chart values. The relevant values path is `kubevirt.spec.configuration`; retain all existing entries in `developerConfiguration.featureGates` when adding the two new entries.

## 2. Select the VM and enable CBT

```bash
kubectl -n default label vm vm1 cbt.kubevirt.io/enabled=true
kubectl -n default get vm vm1 \
  -o jsonpath='{.status.changedBlockTracking.state}{"\n"}'
```

An already running VM normally moves to `PendingRestart`. CBT needs a new VMI so KubeVirt can add the QCOW2 tracking overlay. This stop/start causes guest downtime:

```bash
virtctl -n default stop vm1
kubectl -n default wait --for=delete vmi/vm1 --timeout=5m
virtctl -n default start vm1

kubectl -n default wait \
  --for=jsonpath='{.status.changedBlockTracking.state}'=Enabled \
  vm/vm1 --timeout=5m
kubectl -n default get vmi vm1 \
  -o jsonpath='{.status.changedBlockTracking.state}{"\n"}'
```

Both VM and VMI should report `Enabled` before creating a backup. KubeVirt backs up eligible persistent disks; it does not turn a cloud-init volume into a disk backup. Save the VM specification and any required Secrets or network definitions separately if the goal is full VM recovery. For reference:

```bash
kubectl -n default get vm vm1 -o yaml > vm1-reference.yaml
```

## 3. Create filesystem PVCs for backup output

The **source VM disk** is a Block PVC. The **backup destination** must be a filesystem PVC. Size the full-backup PVC above the source virtual disk size; this example uses 16 GiB for a 10 GiB source. The incremental size depends on the amount of changed data, so 16 GiB also provides simple trial headroom.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm1-cbt-full
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: 1rep
  resources:
    requests:
      storage: 16Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm1-cbt-incremental
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: 1rep
  resources:
    requests:
      storage: 16Gi
EOF

kubectl -n default get pvc vm1-cbt-full vm1-cbt-incremental
```

Wait for both PVCs to become `Bound`. Use a storage class and replica count appropriate for the destination cluster; `1rep` is the single-replica class used for this example.

## 4. Create a tracker and take the full backup

The `VirtualMachineBackupTracker` associates a VM with the latest successful checkpoint. A backup that names this tracker is `Full` when there is no previous checkpoint. Later backups through the same tracker use that checkpoint as their incremental base.

```bash
kubectl apply -f - <<'EOF'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackupTracker
metadata:
  name: vm1-cbt
  namespace: default
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: vm1
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm1-cbt-full
  namespace: default
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm1-cbt
  mode: Push
  pvcName: vm1-cbt-full
EOF
```

Inspect the KubeVirt backup resource by its **fully qualified** name, since Harvester also has a resource called `VirtualMachineBackup`:

```bash
kubectl -n default get virtualmachinebackups.backup.kubevirt.io \
  vm1-cbt-full -o yaml
kubectl -n default get virtualmachinebackuptrackers.backup.kubevirt.io \
  vm1-cbt -o yaml
```

Verify `status.type: Full`, one included disk named `disk-0`, and a nonempty `status.latestCheckpoint` on the tracker. In the backup conditions, require `Done=True` **and** a success reason. `Done=True` by itself can also describe a failed backup.

By default, KubeVirt attempts to freeze the guest filesystem when beginning the backup. A working guest agent improves consistency. If freezing fails, the backup can still complete with a warning; inspect the condition reason and VM events before treating it as application-consistent. Do not set `skipQuiesce: true` unless a crash-consistent backup is acceptable.

## 5. Change guest data and take the incremental backup

Write data to the VM's persistent disk and flush it. For example, inside a Linux guest, choose a path on the root filesystem rather than a memory-backed `/tmp`:

```bash
sudo dd if=/dev/urandom of=/root/cbt-test.bin bs=1M count=50 status=progress
sync
```

Then create a **new** backup resource using the same tracker and a different destination PVC:

```bash
kubectl apply -f - <<'EOF'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm1-cbt-incremental-1
  namespace: default
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm1-cbt
  mode: Push
  pvcName: vm1-cbt-incremental
EOF

kubectl -n default get virtualmachinebackups.backup.kubevirt.io \
  vm1-cbt-incremental-1 -o yaml
kubectl -n default get virtualmachinebackuptrackers.backup.kubevirt.io \
  vm1-cbt -o yaml
```

Require `status.type: Incremental`, a successful `Done` reason, and a tracker checkpoint newer than the full backup's checkpoint. The full and incremental PVCs contain files under `<VM name>/<backup name>-<timestamp>/`; for this VM the disk files are named `vm1-cbt-full-disk-0.qcow2` and `vm1-cbt-incremental-1-disk-0.qcow2`.

Keep the full backup and **every** incremental backup needed to reach the desired restore point. The tracker keeps the latest checkpoint; it is not an archive of the whole chain. If tracker state and retained backup files diverge, take a new full backup before continuing.

## 6. Restore full plus incremental to a new Block PVC

This section restores the state at `vm1-cbt-incremental-1`. It does not modify `vm1` or either backup PVC. The restoration job copies the incremental QCOW2 to temporary storage, sets its backing file to the full QCOW2, and converts the resulting image into a new raw Block PVC.

First create a destination at least as large as the source disk's **virtual size**:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm1-restored-disk
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Block
  storageClassName: 1rep
  resources:
    requests:
      storage: 10Gi
EOF

kubectl -n default get pvc vm1-restored-disk
```

Run the reconstruction job. Its image matches the installed virt-launcher version and includes `qemu-img`. The backup PVCs are mounted read-only. Only `/dev/restore`, which refers to `vm1-restored-disk`, is written. The temporary copy needs enough node ephemeral storage to hold the incremental QCOW2.

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: vm1-cbt-restore
  namespace: default
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: restore
        image: registry.suse.com/suse/sles/16.0/virt-launcher:1.8.4-9.1
        command: ["/bin/sh", "-ec"]
        args:
        - |
          full=$(find /full/vm1 -type f \
            -name 'vm1-cbt-full-disk-0.qcow2' -print -quit)
          incremental=$(find /incremental/vm1 -type f \
            -name 'vm1-cbt-incremental-1-disk-0.qcow2' -print -quit)
          test -n "$full"
          test -n "$incremental"

          qemu-img info "$full"
          qemu-img info "$incremental"
          cp "$incremental" /work/incremental.qcow2

          qemu-img rebase -u -f qcow2 -F qcow2 \
            -b "$full" /work/incremental.qcow2
          qemu-img info --backing-chain /work/incremental.qcow2

          qemu-img convert -p -n -S 0 -f qcow2 -O raw \
            /work/incremental.qcow2 /dev/restore
          sync
          qemu-img compare -f qcow2 -F raw \
            /work/incremental.qcow2 /dev/restore
        securityContext:
          runAsUser: 0
        volumeMounts:
        - {name: full, mountPath: /full, readOnly: true}
        - {name: incremental, mountPath: /incremental, readOnly: true}
        - {name: work, mountPath: /work}
        volumeDevices:
        - {name: restored, devicePath: /dev/restore}
      volumes:
      - name: full
        persistentVolumeClaim:
          claimName: vm1-cbt-full
          readOnly: true
      - name: incremental
        persistentVolumeClaim:
          claimName: vm1-cbt-incremental
          readOnly: true
      - name: work
        emptyDir: {}
      - name: restored
        persistentVolumeClaim:
          claimName: vm1-restored-disk
EOF

kubectl -n default wait --for=condition=complete \
  job/vm1-cbt-restore --timeout=30m
kubectl -n default logs job/vm1-cbt-restore
```

The final `qemu-img compare` should report that the reconstructed image and destination PVC are identical. `-n` tells `qemu-img` to use the existing Block PVC, and `-S 0` writes zero regions rather than relying on the destination already being zeroed. If the job fails, inspect its pod and logs before creating a VM:

```bash
kubectl -n default get pods -l job-name=vm1-cbt-restore
kubectl -n default describe job vm1-cbt-restore
kubectl -n default logs job/vm1-cbt-restore
```

After success, remove the Job to release its claim on the destination PVC. The PVC itself remains:

```bash
kubectl -n default delete job vm1-cbt-restore
kubectl -n default get pvc vm1-restored-disk
```

For a **full-backup-only** restore, convert the full QCOW2 directly to the new Block PVC; the copy and `rebase` commands are unnecessary. With multiple incrementals, copy each incremental into writable work storage, rebase each copy onto the preceding backup in chronological order, then convert the newest one. Never change the archived backup files in place.

## 7. Create and start a new VM

The restored PVC contains a raw boot disk. Create a separate VM from it. The example omits the original VM's MAC address and firmware identifiers, so KubeVirt can assign new ones. It starts halted to allow inspection before connecting the cloned guest to the same network as the original.

```bash
kubectl apply -f - <<'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm1-restored
  namespace: default
spec:
  runStrategy: Halted
  template:
    spec:
      domain:
        cpu:
          cores: 2
        memory:
          guest: 2Gi
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
          interfaces:
          - name: default
            bridge: {}
        resources:
          requests:
            memory: 2Gi
      networks:
      - name: default
        multus:
          networkName: default/mgmt-vlan
      volumes:
      - name: rootdisk
        persistentVolumeClaim:
          claimName: vm1-restored-disk
EOF

kubectl -n default get vm vm1-restored
virtctl -n default start vm1-restored
kubectl -n default get vm,vmi
```

Verify that the guest boots and that the expected file or application data is present. The restored disk retains the original guest hostname, machine ID, SSH host keys, and any static IP configuration. Resolve identity or network conflicts before leaving the original and restored guests running together. This simple VM manifest also does not recreate Harvester-specific VM annotations, referenced cloud-init Secrets, or other external resources from the original VM.

## References

- [KubeVirt v1.8.4 feature gates](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-config/featuregate/active.go)
- [KubeVirt v1.8.4 backup API types](https://github.com/kubevirt/kubevirt/blob/v1.8.4/staging/src/kubevirt.io/api/backup/v1alpha1/types.go)
- [KubeVirt v1.8.4 backup output paths and checkpoint handling](https://github.com/kubevirt/kubevirt/blob/v1.8.4/pkg/virt-launcher/virtwrap/storage/backup.go)
- [QEMU incremental push backup and restore chain](https://www.qemu.org/docs/master/interop/bitmaps.html#example-incremental-push-backups-without-backing-files)
- [QEMU `qemu-img` reference](https://qemu-project.gitlab.io/qemu/tools/qemu-img.html)
