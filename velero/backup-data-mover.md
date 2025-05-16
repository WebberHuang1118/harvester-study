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

Make sure using the right snapshotclass (e.g. for LH, we should use the snapshot class without bak type)
    $ kubectl get volumesnapshotclass -o custom-columns=NAME:.metadata.name,\
    DRIVER:.driver,VELERO:.metadata.labels.velero\\.io/csi-volumesnapshot-class,\
    DEFAULT:.metadata.annotations.snapshot\\.storage\\.kubernetes\\.io/is-default-class


    # Make sure only ONE class carries Velero’s label *or* the default annotation
    $ kubectl label volumesnapshotclass longhorn velero.io/csi-volumesnapshot-class- snapshot.storage.kubernetes.io/is-default-class- --overwrite

    # Make 'snap' the default Velero target
    $ kubectl label volumesnapshotclass longhorn-snapshot velero.io/csi-volumesnapshot-class=true --overwrite

Create a backup:
    $ velero backup create demo \
    --include-namespaces demo \
    --snapshot-move-data \
    --wait

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
            snapshotMoveData: true
            storageLocation: default
            ttl: 720h0m0s
            volumeSnapshotLocations:
            - default
            status:
            backupItemOperationsAttempted: 1
            backupItemOperationsCompleted: 1
            completionTimestamp: "2025-05-09T07:12:01Z"
            expiration: "2025-06-08T07:10:25Z"
            formatVersion: 1.1.0
            hookStatus:
                hooksAttempted: 2
            phase: Completed
            progress:
                itemsBackedUp: 42
                totalItems: 42
            startTimestamp: "2025-05-09T07:10:25Z"
            version: 1
            ```
        
        CR dataupload
            ```
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
            resourceVersion: "1876103"
            uid: 22c971ba-f8e3-490a-9fb4-ececa2572dcc
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
            completionTimestamp: "2025-05-09T07:11:55Z"
            node: harvester-node-0
            path: /22c971ba-f8e3-490a-9fb4-ececa2572dcc
            phase: Completed
            progress:
                bytesDone: 10737418240
                totalBytes: 10737418240
            snapshotID: 3aa9f32e18a921c6bf396e7930ba6584
            startTimestamp: "2025-05-09T07:11:01Z"
            ```

        check the staing pod log at ns velero

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
            ```
    CR velero.io/restore:
        ```
        apiVersion: velero.io/v1
        kind: Restore
        metadata:
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
        completionTimestamp: "2025-05-09T07:21:48Z"
        hookStatus: {}
        phase: Completed
        progress:
            itemsRestored: 15
            totalItems: 15
        restoreItemOperationsAttempted: 1
        restoreItemOperationsCompleted: 1
        startTimestamp: "2025-05-09T07:20:16Z"
        warnings: 4
        ```

    CR DataDownload:
        ```
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
        completionTimestamp: "2025-05-09T07:21:38Z"
        node: harvester-node-0
        phase: Completed
        progress:
            bytesDone: 10737418240
            totalBytes: 10737418240
        startTimestamp: "2025-05-09T07:20:29Z"
        ```

    check the staing pod log at ns velero