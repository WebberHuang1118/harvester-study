# Example: Velero Data Mover Backup & Restore Details

This file demonstrates a full backup and restore workflow using Velero's Data Mover feature with CSI snapshots, including key Custom Resources (CRs), example commands, and sample outputs.

## Restore Command

```sh
velero restore describe demo-r --details
```

## DataDownload Command

```sh
kubectl get datadownload -n velero
```

## Sample Custom Resources

```yaml
# Restore
Name:         demo-r
Namespace:    velero
Labels:       <none>
Annotations:  <none>

Phase:                       Completed
Total items to be restored:  15
Items restored:              15

Started:    2025-05-09 15:20:16 +0800 CST
Completed:  2025-05-09 15:21:48 +0800 CST

Warnings:
Velero:     <none>
Cluster:  could not restore, CustomResourceDefinition "datavolumes.cdi.kubevirt.io" already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, CustomResourceDefinition "virtualmachineinstances.kubevirt.io" already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, CustomResourceDefinition "virtualmachines.kubevirt.io" already exists. Warning: the in-cluster version is different than the backed-up version
Namespaces:
    demo:  could not restore, ConfigMap "kube-root-ca.crt" already exists. Warning: the in-cluster version is different than the backed-up version

Backup:  demo

Namespaces:
Included:  all namespaces found in the backup
Excluded:  <none>

Resources:
Included:        *
Excluded:        nodes, events, events.events.k8s.io, backups.velero.io, restores.velero.io, resticrepositories.velero.io, csinodes.storage.k8s.io, volumeattachments.storage.k8s.io, backuprepositories.velero.io
Cluster-scoped:  auto

Namespace mappings:  <none>

Label selector:  <none>

Or label selector:  <none>

Restore PVs:  auto

CSI Snapshot Restores:
demo/vm1-disk-0-y4ge6:
    Data Movement:
    Operation ID: dd-6ff69830-d28f-4033-ad90-a5265414b6ea.19ec0575-d17d-4684966e6
    Data Mover: velero
    Uploader Type: kopia

Existing Resource Policy:   <none>
ItemOperationTimeout:       4h0m0s

Preserve Service NodePorts:  auto

Uploader config:
Write Sparse Files:  true

Restore Item Operations:
Operation for persistentvolumeclaims demo/vm1-disk-0-y4ge6:
    Restore Item Action Plugin:  velero.io/csi-pvc-restorer
    Operation ID:                dd-6ff69830-d28f-4033-ad90-a5265414b6ea.19ec0575-d17d-4684966e6
    Phase:                       Completed
    Progress:                    10737418240 of 10737418240 complete (Bytes)
    Progress description:        Completed
    Created:                     2025-05-09 15:20:17 +0800 CST
    Started:                     2025-05-09 15:20:29 +0800 CST
    Updated:                     2025-05-09 15:21:38 +0800 CST

HooksAttempted:   0
HooksFailed:      0

Resource List:
apiextensions.k8s.io/v1/CustomResourceDefinition:
    - datavolumes.cdi.kubevirt.io(failed)
    - virtualmachineinstances.kubevirt.io(failed)
    - virtualmachines.kubevirt.io(failed)
apps/v1/ControllerRevision:
    - demo/revision-start-vm-3edbfc2c-f7db-4253-b135-ca55e11ead65-1(created)
cdi.kubevirt.io/v1beta1/DataVolume:
    - demo/vm1-disk-0-y4ge6(created)
kubevirt.io/v1/VirtualMachine:
    - demo/vm1(created)
kubevirt.io/v1/VirtualMachineInstance:
    - demo/vm1(skipped)
v1/ConfigMap:
    - demo/kube-root-ca.crt(failed)
v1/Namespace:
    - demo(created)
v1/PersistentVolume:
    - pvc-af9d072a-5598-4630-98da-4e8ff214574a(skipped)
v1/PersistentVolumeClaim:
    - demo/vm1-disk-0-y4ge6(created)
v1/Pod:
    - demo/virt-launcher-vm1-xxrqq(skipped)
v1/Secret:
    - demo/vm1-jldst(created)
v1/ServiceAccount:
    - demo/default(skipped)
velero.io/v2alpha1/DataUpload:
    - velero/demo-dnb5q(skipped)

---
# DataDownload
apiVersion: velero.io/v2alpha1
kind: DataDownload
metadata:
  name: demo-r-s7psj
  namespace: velero
  ownerReferences:
    - apiVersion: velero.io/v1
      controller: true
      kind: Restore
      name: demo-r
      uid: 6ff69830-d28f-4033-ad90-a5265414b6ea
spec:
  backupStorageLocation: default
  dataMoverConfig:
    WriteSparseFiles: "true"
  operationTimeout: 10m0s
  snapshotID: 3aa9f32e18a921c6bf396e7930ba6584
  sourceNamespace: demo
  targetVolume:
    namespace: demo
    pv: ""
    pvc: vm1-disk-0-y4ge6
status:
  phase: Completed
  progress:
    bytesDone: 10737418240
    totalBytes: 10737418240
  completionTimestamp: "2025-05-09T07:21:38Z"
  startTimestamp: "2025-05-09T07:20:29Z"
```

## Notes

- Ensure all CRs have `phase: Completed` for a successful workflow.
- Adjust names, namespaces, and storage classes as needed for your environment.
- The number of items and resource names will vary based on your setup.
