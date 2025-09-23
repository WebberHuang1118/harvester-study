# Enabling Harvester CSI Driver Volume Snapshots on a k3s Guest Cluster

This guide explains how to enable and use the Harvester CSI driver with Volume Snapshot support on a k3s guest cluster.

## 1. Deploy the Harvester CSI Driver

- **Reference:**
  - [Harvester CSI Driver Deployment Guide](https://docs.harvesterhci.io/v1.7/rancher/csi-driver/#deploying-with-harvester-k3s-node-driver)
- **Steps:**
  1. Generate the cloud-config for your k3s guest cluster:
     ```sh
     ./generate_addon_csi.sh <serviceaccount-name> <namespace> k3s
     ```
  2. Retrieve the generated cloud-init file at `harvester-csi-for-k3s/k3s-cloudinit`.
  3. Copy the cloud-init user data to the guest node VM's **User Data** field.
  4. Install the Harvester CSI driver via the Rancher Marketplace.

## 2. Enable CSI Snapshot Support on the Guest k3s Cluster

- **Reference:**
  - [Longhorn CSI Snapshot Support](https://longhorn.io/docs/1.9.1/snapshots-and-backups/csi-snapshot-support/enable-csi-snapshot-support/)
- **Steps:**
  1. **Install the Snapshot CRDs:**
     - Download the CRDs from [external-snapshotter v8.3.0 CRDs](https://github.com/kubernetes-csi/external-snapshotter/tree/v8.3.0/client/config/crd) (Longhorn v1.9.1 uses CSI external-snapshotter v8.3.0).
     - Apply the CRDs:
       ```sh
       kubectl create -k client/config/crd
       ```
  2. **Install the Common Snapshot Controller:**
     - Download the manifests from [external-snapshotter v8.3.0 snapshot-controller](https://github.com/kubernetes-csi/external-snapshotter/tree/v8.3.0/deploy/kubernetes/snapshot-controller).
     - Update the namespace in the manifests to match your environment (e.g., `kube-system`).
     - Apply the manifests:
       ```sh
       kubectl create -k deploy/kubernetes/snapshot-controller
       ```

## 3. Configure Required RBAC

- Bind the `ClusterRole` `harvesterhci.io:csi-driver` to the guest cluster's service account on Harvester.
- Example:
  ```sh
  kubectl apply -f harvester-csi-for-k3s/csi-rbac.yaml
  ```

## 4. Create and Restore CSI Snapshots

- For example manifests and procedures, see the [`guest-snapshot`](../guest-snapshot/) directory.
