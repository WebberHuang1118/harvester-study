# Example: Velero Backup Details

This file shows a sample output and explanation for a Velero backup operation.

## Command
```sh
velero backup describe demo --details
```

## Sample Output
```
Name:         demo
Namespace:    velero
Labels:       velero.io/storage-location=default
Annotations:  velero.io/resource-timeout=10m0s
            velero.io/source-cluster-k8s-gitversion=v1.32.3+rke2r1
            velero.io/source-cluster-k8s-major-version=1
            velero.io/source-cluster-k8s-minor-version=32

Phase:  Completed


Namespaces:
Included:  demo
Excluded:  <none>

Resources:
Included:        *
Excluded:        <none>
Cluster-scoped:  auto

Label selector:  <none>

Or label selector:  <none>

Storage Location:  default

Velero-Native Snapshot PVs:  auto
Snapshot Move Data:          false
Data Mover:                  velero

TTL:  720h0m0s

CSISnapshotTimeout:    10m0s
ItemOperationTimeout:  4h0m0s

Hooks:  <none>

Backup Format Version:  1.1.0

Started:    2025-05-13 18:52:12 +0800 CST
Completed:  2025-05-13 18:53:00 +0800 CST

Expiration:  2025-06-12 18:52:12 +0800 CST

Total items to be backed up:  36
Items backed up:              36

Backup Item Operations:
Operation for volumesnapshots.snapshot.storage.k8s.io demo/velero-os-vol-wvwn2:
    Backup Item Action Plugin:  velero.io/csi-volumesnapshot-backupper
    Operation ID:               demo/velero-os-vol-wvwn2/2025-05-13T10:52:30Z
    Items to Update:
            volumesnapshots.snapshot.storage.k8s.io demo/velero-os-vol-wvwn2
            volumesnapshotcontents.snapshot.storage.k8s.io /snapcontent-6cce7f0e-14cd-464e-a988-fe5c38923245
    Phase:    Completed
    Created:  2025-05-13 18:52:30 +0800 CST
    Started:  2025-05-13 18:52:30 +0800 CST
    Updated:  2025-05-13 18:52:58 +0800 CST
Resource List:
apiextensions.k8s.io/v1/CustomResourceDefinition:
    - virtualmachineinstances.kubevirt.io
    - virtualmachines.kubevirt.io
apps/v1/ControllerRevision:
    - demo/revision-start-vm-3221d1a5-28de-4394-a5fc-616b4921ba6c-1
kubevirt.io/v1/VirtualMachine:
    - demo/vm1
kubevirt.io/v1/VirtualMachineInstance:
    - demo/vm1
policy/v1/PodDisruptionBudget:
    - demo/kubevirt-disruption-budget-whcxz
snapshot.storage.k8s.io/v1/VolumeSnapshot:
    - demo/velero-os-vol-wvwn2
snapshot.storage.k8s.io/v1/VolumeSnapshotClass:
    - longhorn
snapshot.storage.k8s.io/v1/VolumeSnapshotContent:
    - snapcontent-6cce7f0e-14cd-464e-a988-fe5c38923245
v1/ConfigMap:
    - demo/kube-root-ca.crt
v1/Event:
    - demo/os-vol.183f107af6471ae0
    - demo/os-vol.183f107af680e599
    - demo/os-vol.183f107b7970e576
    - demo/virt-launcher-vm1-n5529.183f1081244810f1
    - demo/virt-launcher-vm1-n5529.183f1083175fcf64
    - demo/virt-launcher-vm1-n5529.183f108326f4420a
    - demo/virt-launcher-vm1-n5529.183f108326f4768a
    - demo/virt-launcher-vm1-n5529.183f10833416d811
    - demo/virt-launcher-vm1-n5529.183f1083353d6126
    - demo/virt-launcher-vm1-n5529.183f10833f3b47ee
    - demo/virt-launcher-vm1-n5529.183f10834112e3dd
    - demo/virt-launcher-vm1-n5529.183f108345608603
    - demo/virt-launcher-vm1-n5529.183f1083456783cc
    - demo/virt-launcher-vm1-n5529.183f10834702ce99
    - demo/virt-launcher-vm1-n5529.183f108356f00975
    - demo/vm1.183f108120c2fc38
    - demo/vm1.183f1081236ab222
    - demo/vm1.183f1083b3140aaa
    - demo/vm1.183f1083b436bf4a
    - demo/vm1.183f1083b5398131
v1/Namespace:
    - demo
v1/PersistentVolume:
    - pvc-87d267d7-5da2-427a-8eef-958c0061dfc1
v1/PersistentVolumeClaim:
    - demo/os-vol
v1/Pod:
    - demo/virt-launcher-vm1-n5529
v1/Secret:
    - demo/vm1-kfops
v1/ServiceAccount:
    - demo/default

Backup Volumes:
Velero-Native Snapshots: <none included>

CSI Snapshots:
    demo/os-vol:
    Snapshot:
        Operation ID: demo/velero-os-vol-wvwn2/2025-05-13T10:52:30Z
        Snapshot Content Name: snapcontent-6cce7f0e-14cd-464e-a988-fe5c38923245
        Storage Snapshot ID: bak://pvc-87d267d7-5da2-427a-8eef-958c0061dfc1/backup-2b4f7574b49e4ac8
        Snapshot Size (bytes): 5368709120
        CSI Driver: driver.longhorn.io
        Result: succeeded

Pod Volume Backups: <none included>

HooksAttempted:  2
HooksFailed:     0
```

## Notes
- Ensure the backup phase is `Completed` and CSI snapshots are present.
- The number of items and resource names will vary based on your environment.
