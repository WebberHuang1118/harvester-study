# Example: Velero Restore Details

This file shows a sample output and explanation for a Velero restore operation.

## Command
```sh
velero restore describe --details demo-r
```

## Sample Output
```
Name:         demo-r
Namespace:    velero
Labels:       <none>
Annotations:  <none>

Phase:                       Completed
Total items to be restored:  16
Items restored:              16

Started:    2025-05-13 18:54:30 +0800 CST
Completed:  2025-05-13 18:54:48 +0800 CST

Warnings:
Velero:     <none>
Cluster:  could not restore, CustomResourceDefinition "virtualmachineinstances.kubevirt.io" already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, CustomResourceDefinition "virtualmachines.kubevirt.io" already exists. Warning: the in-cluster version is different than the backed-up version
            could not restore, VolumeSnapshotContent "snapcontent-6cce7f0e-14cd-464e-a988-fe5c38923245" already exists. Warning: the in-cluster version is different than the backed-up version
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
demo/os-vol:
    Snapshot:
    Snapshot Content Name: velero-os-vol-wvwn2-zfbmd
    Storage Snapshot ID: bak://pvc-87d267d7-5da2-427a-8eef-958c0061dfc1/backup-2b4f7574b49e4ac8
    CSI Driver: driver.longhorn.io

Existing Resource Policy:   <none>
ItemOperationTimeout:       4h0m0s

Preserve Service NodePorts:  auto

Uploader config:
Write Sparse Files:  true


HooksAttempted:   0
HooksFailed:      0

Resource List:
apiextensions.k8s.io/v1/CustomResourceDefinition:
    - virtualmachineinstances.kubevirt.io(failed)
    - virtualmachines.kubevirt.io(failed)
apps/v1/ControllerRevision:
    - demo/revision-start-vm-3221d1a5-28de-4394-a5fc-616b4921ba6c-1(created)
kubevirt.io/v1/VirtualMachine:
    - demo/vm1(created)
kubevirt.io/v1/VirtualMachineInstance:
    - demo/vm1(skipped)
policy/v1/PodDisruptionBudget:
    - demo/kubevirt-disruption-budget-whcxz(created)
snapshot.storage.k8s.io/v1/VolumeSnapshot:
    - demo/velero-os-vol-wvwn2(created)
snapshot.storage.k8s.io/v1/VolumeSnapshotClass:
    - longhorn(skipped)
snapshot.storage.k8s.io/v1/VolumeSnapshotContent:
    - snapcontent-6cce7f0e-14cd-464e-a988-fe5c38923245(failed)
v1/ConfigMap:
    - demo/kube-root-ca.crt(failed)
v1/Namespace:
    - demo(created)
v1/PersistentVolume:
    - pvc-87d267d7-5da2-427a-8eef-958c0061dfc1(skipped)
v1/PersistentVolumeClaim:
    - demo/os-vol(created)
v1/Pod:
    - demo/virt-launcher-vm1-n5529(skipped)
v1/Secret:
    - demo/vm1-kfops(created)
v1/ServiceAccount:
    - demo/default(skipped)
```

## Notes
- Review the restore status and warnings. Some resources may already exist and be skipped or produce warnings if their versions differ.
- The number of restored items and warnings will vary based on your environment.
