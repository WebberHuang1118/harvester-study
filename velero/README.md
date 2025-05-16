# Velero Installation Guide

This guide provides steps to install and uninstall Velero with S3-compatible storage and CSI support.

## Prerequisites
- Velero CLI installed
- Access to a Kubernetes cluster
- S3-compatible storage (e.g., MinIO)
- Credentials file (`credentials-velero`) in the current directory

## Installation

```sh
export BUCKET=velero
export REGION=pcloud
export VELERO_NS=velero

velero install \
  --provider aws \
  --plugins quay.io/kubevirt/kubevirt-velero-plugin:v0.8.0,velero/velero-plugin-for-aws:v1.12.0 \
  --bucket "$BUCKET" \
  --secret-file ./credentials-velero \
  --backup-location-config 'region=pcloud,s3ForcePathStyle=true,s3Url=http://192.188.0.56:9000' \
  --use-node-agent \
  --privileged-node-agent \
  --features=EnableCSI
```

### Verify Installation
```sh
velero backup-location get
```

## Uninstall
```sh
velero uninstall --force
```

## Notes
- Adjust the `s3Url` and `region` as needed for your environment.
- Ensure the `credentials-velero` file contains the correct access keys for your S3 storage.

## CSI Manifest-Only Backup and Restore (Longhorn Example)

This section describes how to perform backup and restore of VM workloads using Velero with CSI snapshot support (e.g., Longhorn).

### 1. Prepare the Environment
- Create the target namespace and VM:
  ```sh
  kubectl apply -f velero/example/ns.yaml
  # Create a VM and its PVC as needed
  ```

### 2. Ensure Correct VolumeSnapshotClass
- List available snapshot classes:
  ```sh
  kubectl get volumesnapshotclass -o custom-columns=NAME:.metadata.name,DRIVER:.driver,VELERO:.metadata.labels.velero\\.io/csi-volumesnapshot-class,DEFAULT:.metadata.annotations.snapshot\\.storage\\.kubernetes\\.io/is-default-class
  ```
- Ensure only one class has the Velero label or default annotation:
  ```sh
  kubectl label volumesnapshotclass longhorn-snapshot velero.io/csi-volumesnapshot-class- snapshot.storage.kubernetes.io/is-default-class- --overwrite
  kubectl label volumesnapshotclass longhorn velero.io/csi-volumesnapshot-class=true --overwrite
  ```

### 3. Create a Backup
- Run the backup command:
  ```sh
  velero backup create demo --include-namespaces demo --snapshot-move-data=false --wait
  velero backup describe demo --details
  ```
- Confirm the backup phase is `Completed` and CSI snapshots are present.

### 4. Simulate Disaster Recovery (Optional)
- Delete the namespace to simulate a DR scenario:
  ```sh
  kubectl delete namespaces demo --force
  ```

### 5. Restore from Backup
- Restore the backup:
  ```sh
  velero restore create demo-r --from-backup demo --write-sparse-files --wait
  velero restore describe --details demo-r
  ```
- Review the restore status and warnings. Some resources (e.g., CRDs, ConfigMaps) may already exist and be skipped or produce warnings if their versions differ.

### Notes
- This workflow requires a CSI driver that supports remote backup (e.g., Longhorn with a proper snapshot class).
- Only one VolumeSnapshotClass should be labeled for Velero at a time.
- For more details and output samples, refer to `velero/example`.

## Velero Filesystem Backup (FSB) for Backup/Restore

This section describes how to use Velero's Filesystem Backup (FSB) feature to back up and restore a VM with a filesystem-mode (RWX) PVC.

### 1. Prepare the VM and PVC
- Create a VM using a PVC in filesystem (RWX) mode, typically from a third-party VM image.

### 2. Deploy the FSB Helper Pod
- Edit `fsb-helper.yaml` to ensure the PVC name matches your VM's PVC.
- Apply the helper pod:
  ```sh
  kubectl apply -f fsb-helper.yaml
  ```

### 3. Create a Backup
- Run the following command to create a backup (replace `demo` and namespace as needed):
  ```sh
  velero backup create demo \
    --include-namespaces demo \
    --snapshot-volumes=false \
    --default-volumes-to-fs-backup \
    --wait
  ```

### 4. Simulate Disaster Recovery (Optional)
- Delete the namespace to simulate a disaster recovery scenario:
  ```sh
  kubectl delete namespace demo --force
  ```

### 5. Restore from Backup
- Restore the backup:
  ```sh
  velero restore create demo-r --from-backup demo --write-sparse-files --wait
  ```
- Note: The VM may not boot immediately after restore. Wait for the fsb-helper pod to be running, then restart the VM.

### 6. Related Resources to Check
- Velero custom resources:
  - Backup
  - PodVolumeBackup
  - Restore
  - PodVolumeRestore

## CSI Snapshot + Data Mover Backup/Restore

This section describes how to use Velero's CSI snapshot capability with the Data Mover feature to perform full backup and restore of VM workloads, including moving snapshot data to external storage (e.g., S3) for disaster recovery.

### 1. Prepare the Environment
- Create the target namespace and VM:
  ```sh
  kubectl apply -f ns.yaml
  # Create a VM and its PVC as needed (ensure the PVC uses a supported CSI storage class)
  ```

### 2. Ensure Correct VolumeSnapshotClass
- List available snapshot classes:
  ```sh
  kubectl get volumesnapshotclass -o custom-columns=NAME:.metadata.name,DRIVER:.driver,VELERO:.metadata.labels.velero\\.io/csi-volumesnapshot-class,DEFAULT:.metadata.annotations.snapshot\\.storage\\.kubernetes\\.io/is-default-class
  ```
- Ensure only one class has the Velero label or default annotation:
  ```sh
  kubectl label volumesnapshotclass <your-snapshotclass> velero.io/csi-volumesnapshot-class=true --overwrite
  # Remove the label/annotation from other classes if needed
  ```

### 3. Create a Backup with Data Mover
- Run the backup command with Data Mover enabled:
  ```sh
  velero backup create demo \
    --include-namespaces demo \
    --snapshot-move-data \
    --wait
  velero backup describe demo --details
  ```
- Confirm the backup phase is `Completed` and that `Snapshot Move Data: true` and `Data Mover: velero` are present in the details.
- Velero will create CSI snapshots and move the data to the backup storage location using a DataUpload custom resource.

### 4. Simulate Disaster Recovery (Optional)
- Delete the namespace to simulate a DR scenario:
  ```sh
  kubectl delete namespaces demo --force
  ```

### 5. Restore from Backup
- Restore the backup and write sparse files:
  ```sh
  velero restore create demo-r --from-backup demo --write-sparse-files --wait
  velero restore describe --details demo-r
  ```
- Confirm the restore phase is `Completed` and that Data Mover is used for the PVC restore (see `CSI Snapshot Restores` and `Data Movement` sections).
- Velero will use a DataDownload custom resource to move the data back from the backup storage location.

### 6. Troubleshooting
- Check the logs of the staging pod in the `velero` namespace for Data Mover activity:
  ```sh
  kubectl logs -n velero -l component=velero
  ```
- Inspect the following custom resources for status and progress:
  - Backup (`velero.io/Backup`)
  - DataUpload (`velero.io/v2alpha1/DataUpload`)
  - Restore (`velero.io/Restore`)
  - DataDownload (`velero.io/v2alpha1/DataDownload`)

### Notes
- Only one VolumeSnapshotClass should be labeled for Velero at a time.
- The Data Mover feature is required for off-cluster backup/restore with CSI snapshots.
- For more details and output samples, see `velero/example`.
