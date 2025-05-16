Install:
    export BUCKET=velero
    export REGION=pcloud
    export VELERO_NS=velero

    velero install \
    --provider aws \
    --plugins \
        quay.io/kubevirt/kubevirt-velero-plugin:v0.8.0,velero/velero-plugin-for-aws:v1.12.0 \
    --bucket "$BUCKET" \
    --secret-file ./credentials-velero \
    --backup-location-config 'region=pcloud,s3ForcePathStyle=true,s3Url=http://192.188.0.56:9000' \
    --use-node-agent \
    --privileged-node-agent \
    --features=EnableCSI    

    check install:
        velero backup-location get

Uninstall:
    velero uninstall --force

Create the VM for backup/restore:
    $ kubectl apply -f ns.yaml
    Creating a vmimage from third-party, and boot a VM with this pvc

Make sure using the right snapshotclass, this is only feasible for CSI snapshot support remote backup like LH with snapshotclass with bak type, this scenario will fail if the csi driver does not support remote backup.
    $ kubectl get volumesnapshotclass -o custom-columns=NAME:.metadata.name,\
    DRIVER:.driver,VELERO:.metadata.labels.velero\\.io/csi-volumesnapshot-class,\
    DEFAULT:.metadata.annotations.snapshot\\.storage\\.kubernetes\\.io/is-default-class


    # Make sure only ONE class carries Velero’s label *or* the default annotation
    $ kubectl label volumesnapshotclass longhorn-snapshot velero.io/csi-volumesnapshot-class- snapshot.storage.kubernetes.io/is-default-class- --overwrite

    # Make 'snap' the default Velero target
    $ kubectl label volumesnapshotclass longhorn velero.io/csi-volumesnapshot-class=true --overwrite

Create a backup:
    $ velero backup create demo --include-namespaces demo --snapshot-move-data=false --wait

    check the status:
        $ velero backup describe demo --details
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
 
        CR velero.io/backup
            ```
            apiVersion: velero.io/v1
            kind: Backup
            metadata:
            name: demo
            namespace: velero
            spec:
                csiSnapshotTimeout: 10m0s
                defaultVolumesToFsBackup: false
                hooks: {}
                includedNamespaces:
                - demo
                itemOperationTimeout: 4h0m0s
                metadata: {}
                snapshotMoveData: false
                storageLocation: default
                ttl: 720h0m0s
                volumeSnapshotLocations:
                - default
            status:
                backupItemOperationsAttempted: 1
                backupItemOperationsCompleted: 1
                completionTimestamp: "2025-05-13T10:53:00Z"
                csiVolumeSnapshotsAttempted: 1
                csiVolumeSnapshotsCompleted: 1
                expiration: "2025-06-12T10:52:12Z"
                formatVersion: 1.1.0
                hookStatus:
                    hooksAttempted: 2
                phase: Completed
                progress:
                    itemsBackedUp: 36
                    totalItems: 36
                startTimestamp: "2025-05-13T10:52:12Z"
                version: 1
            ```

Simulate DR:
    $ kubectl delete namespaces demo --force

Restore from backup
    $ velero restore create demo-r --from-backup demo --write-sparse-files --wait

    check the restore status:
        $ velero restore describe --details demo-r
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
    CR velero.io/restore:
        ```
        apiVersion: velero.io/v1
        kind: Restore
        metadata:
        creationTimestamp: "2025-05-13T10:54:30Z"
        finalizers:
        - restores.velero.io/external-resources-finalizer
        name: demo-r
        namespace: velero
        spec:
            backupName: demo
            excludedResources:
            - nodes
            - events
            - events.events.k8s.io
            - backups.velero.io
            - restores.velero.io
            - resticrepositories.velero.io
            - csinodes.storage.k8s.io
            - volumeattachments.storage.k8s.io
            - backuprepositories.velero.io
            hooks: {}
            includedNamespaces:
            - '*'
            itemOperationTimeout: 4h0m0s
            uploaderConfig:
                writeSparseFiles: true
        status:
            completionTimestamp: "2025-05-13T10:54:48Z"
            hookStatus: {}
            phase: Completed
            progress:
                itemsRestored: 16
                totalItems: 16
            startTimestamp: "2025-05-13T10:54:30Z"
            warnings: 4
        ```