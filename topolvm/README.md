# TopoLVM Setup Guide

This guide provides step-by-step instructions to install, configure, and uninstall TopoLVM in a Kubernetes environment. For more detailed information, refer to the [official TopoLVM documentation](https://github.com/topolvm/topolvm/blob/v0.36.4/docs/getting-started.md).

## Prerequisites

- A Kubernetes cluster.
- A block device (e.g., `/dev/sdb`) available on the Kubernetes nodes.
- Helm installed on your local machine.

## Create a Volume Group (VG) on Kubernetes Node

1. Initialize the physical volume:
   ```bash
   pvcreate /dev/sdb
   ```
2. Create a volume group:
   ```bash
   vgcreate myvg1 /dev/sdb
   ```
3. Create a thin pool:
   ```bash
   lvcreate --type thin-pool -L 20G -n pool0 myvg1
   ```

## Install and Use TopoLVM

1. Label the required namespaces:
   ```bash
   kubectl label namespace topolvm-system topolvm.io/webhook=ignore
   kubectl label namespace kube-system topolvm.io/webhook=ignore
   ```
2. Install Cert-Manager:
   ```bash
   CERT_MANAGER_VERSION=v1.17.1
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml
   ```
3. Create the `topolvm-system` namespace:
   ```bash
   kubectl create namespace topolvm-system
   ```
4. Install TopoLVM using Helm:
   ```bash
   helm install --namespace=topolvm-system topolvm topolvm/topolvm --set cert-manager.enabled=true --version 15.5.3
   ```
5. Scale down the `topolvm-controller` deployment:
   ```bash
   kubectl -n topolvm-system patch deployment topolvm-controller --type='merge' -p '{"spec":{"replicas":1}}'
   ```
6. Delete the default storage class:
   ```bash
   kubectl delete storageclasses.storage.k8s.io topolvm-provisioner
   ```

## Create Storage Class, PVC, and Pod

1. Apply the custom storage class configuration:
   ```bash
   kubectl apply -f sc.yaml
   ```
2. Create a PersistentVolumeClaim (PVC) using `blk-pvc.yaml`:
   ```bash
   kubectl apply -f blk-pvc.yaml
   ```
3. Deploy a pod using the created PVC by applying `blk-pod.yaml`:
   ```bash
   kubectl apply -f blk-pod.yaml
   ```

### Expand PVC Size

1. Patch the PVC to request more storage:
   ```bash
   kubectl patch pvc topolvm-blk-pvc \
   -n default \
   --type='merge' \
   -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'
   ```
2. Verify the updated block device size inside the pod:
   ```bash
   blockdev --getsize64 /dev/topolvm-blk-pvc
   ```
   Example output:
   ```
   5368709120
   ```

## Uninstall TopoLVM

1. Uninstall TopoLVM using Helm:
   ```bash
   helm uninstall topolvm -n topolvm-system
   ```
2. Delete the `topolvm-system` namespace:
   ```bash
   kubectl delete namespace topolvm-system
   ```
3. Remove the logical volume, volume group, and physical volume:
   ```bash
   lvremove -y /dev/myvg1/pool0
   vgremove -y myvg1
   pvremove -y /dev/sdb
   ```
4. Delete the storage class:
   ```bash
   kubectl delete sc topolvm-provisioner
   ```