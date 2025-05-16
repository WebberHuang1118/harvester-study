# Example: Velero Data Mover Backup & Restore Details

This file demonstrates a full backup and restore workflow using Velero's Data Mover feature with CSI snapshots, including key Custom Resources (CRs), example commands, and sample outputs.

## Backup Command

```sh
velero backup describe demo --details
```

## DataUpload Command

```sh
kubectl get dataupload -n velero
```

## Sample Custom Resources

```yaml
# Backup
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
Snapshot Move Data:          true
Data Mover:                  velero

TTL:  720h0m0s

CSISnapshotTimeout:    10m0s
ItemOperationTimeout:  4h0m0s

Hooks:  <none>

Backup Format Version:  1.1.0

Started:    2025-05-09 15:10:25 +0800 CST
Completed:  2025-05-09 15:12:01 +0800 CST

Expiration:  2025-06-08 15:10:25 +0800 CST

Total items to be backed up:  42
Items backed up:              42

Backup Item Operations:
Operation for persistentvolumeclaims demo/vm1-disk-0-y4ge6:
    Backup Item Action Plugin:  velero.io/csi-pvc-backupper
    Operation ID:               du-763b6044-5605-4607-9cbb-2bbeba1c43ef.19ec0575-d17d-468cccb8a
    Items to Update:
                        datauploads.velero.io velero/demo-dnb5q
    Phase:                 Completed
    Progress:              10737418240 of 10737418240 complete (Bytes)
    Progress description:  Completed
    Created:               2025-05-09 15:10:31 +0800 CST
    Started:               2025-05-09 15:11:01 +0800 CST
    Updated:               2025-05-09 15:11:55 +0800 CST
Resource List:
apiextensions.k8s.io/v1/CustomResourceDefinition:
    - datavolumes.cdi.kubevirt.io
    - virtualmachineinstances.kubevirt.io
    - virtualmachines.kubevirt.io
apps/v1/ControllerRevision:
    - demo/revision-start-vm-3edbfc2c-f7db-4253-b135-ca55e11ead65-1
cdi.kubevirt.io/v1beta1/DataVolume:
    - demo/vm1-disk-0-y4ge6
kubevirt.io/v1/VirtualMachine:
    - demo/vm1
kubevirt.io/v1/VirtualMachineInstance:
    - demo/vm1
v1/ConfigMap:
    - demo/kube-root-ca.crt
v1/Event:
    - demo/virt-launcher-vm1-xxrqq.183dc9ff8b5bf860
    - demo/virt-launcher-vm1-xxrqq.183dca006ca29d2f
    - demo/virt-launcher-vm1-xxrqq.183dca006ca33d37
    - demo/virt-launcher-vm1-xxrqq.183dca0092bb6726
    - demo/virt-launcher-vm1-xxrqq.183dca009994d04e
    - demo/virt-launcher-vm1-xxrqq.183dca00c5c59cd2
    - demo/virt-launcher-vm1-xxrqq.183dca00ce5be4fe
    - demo/virt-launcher-vm1-xxrqq.183dca00e068fe75
    - demo/virt-launcher-vm1-xxrqq.183dca00e0bf6c44
    - demo/virt-launcher-vm1-xxrqq.183dca00e42e9953
    - demo/virt-launcher-vm1-xxrqq.183dca0118f23879
    - demo/vm1-disk-0-y4ge6.183dc9f453b0e36a
    - demo/vm1-disk-0-y4ge6.183dc9f45da05c97
    - demo/vm1-disk-0-y4ge6.183dc9f45ed9485e
    - demo/vm1-disk-0-y4ge6.183dc9f4614a13b0
    - demo/vm1-disk-0-y4ge6.183dc9f4614a6699
    - demo/vm1-disk-0-y4ge6.183dc9f476172994
    - demo/vm1-disk-0-y4ge6.183dc9f610d3a548
    - demo/vm1-disk-0-y4ge6.183dc9f611438825
    - demo/vm1-disk-0-y4ge6.183dc9f611702814
    - demo/vm1-disk-0-y4ge6.183dc9f611705d68
    - demo/vm1-disk-0-y4ge6.183dc9fd4ae4bd79
    - demo/vm1-disk-0-y4ge6.183dc9ff7f816e7f
    - demo/vm1-disk-0-y4ge6.183dc9ff84e40f61
    - demo/vm1.183dc9f45690a0b2
    - demo/vm1.183dc9ff88d4f676
    - demo/vm1.183dca0228f3f708
    - demo/vm1.183dca0232d689dd
v1/Namespace:
    - demo
v1/PersistentVolume:
    - pvc-af9d072a-5598-4630-98da-4e8ff214574a
v1/PersistentVolumeClaim:
    - demo/vm1-disk-0-y4ge6
v1/Pod:
    - demo/virt-launcher-vm1-xxrqq
v1/Secret:
    - demo/vm1-jldst
v1/ServiceAccount:
    - demo/default

Backup Volumes:
Velero-Native Snapshots: <none included>

CSI Snapshots:
    demo/vm1-disk-0-y4ge6:
    Data Movement:
        Operation ID: du-763b6044-5605-4607-9cbb-2bbeba1c43ef.19ec0575-d17d-468cccb8a
        Data Mover: velero
        Uploader Type: kopia
        Moved data Size (bytes): 10737418240
        Result: succeeded

Pod Volume Backups: <none included>

HooksAttempted:  2
HooksFailed:     0

---
# DataUpload
apiVersion: velero.io/v2alpha1
kind: DataUpload
metadata:
  name: demo-dnb5q
  namespace: velero
  ownerReferences:
    - apiVersion: velero.io/v1
      controller: true
      kind: Backup
      name: demo
      uid: 763b6044-5605-4607-9cbb-2bbeba1c43ef
spec:
  backupStorageLocation: default
  csiSnapshot:
    snapshotClass: csi-hostpath-snapclass
    storageClass: csi-hostpath-sc
    volumeSnapshot: velero-vm1-disk-0-y4ge6-mf8q6
  operationTimeout: 10m0s
  snapshotType: CSI
  sourceNamespace: demo
  sourcePVC: vm1-disk-0-y4ge6
status:
  phase: Completed
  progress:
    bytesDone: 10737418240
    totalBytes: 10737418240
  completionTimestamp: "2025-05-09T07:11:55Z"
  startTimestamp: "2025-05-09T07:11:01Z"
```

## Notes

- Ensure all CRs have `phase: Completed` for a successful workflow.
- Adjust names, namespaces, and storage classes as needed for your environment.
- The number of items and resource names will vary based on your setup.
