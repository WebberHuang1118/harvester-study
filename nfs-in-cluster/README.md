# NFS In-Cluster Example

This guide demonstrates how to deploy an in-cluster NFS server, install the NFS CSI driver, and use it for dynamic provisioning, snapshot, and restore in Kubernetes.

## Steps

### 1. Deploy In-Cluster NFS Server

```sh
kubectl apply -f nfs-server.yaml
```

### 2. Deploy NFS CSI Driver

```sh
curl -skSL https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/deploy/install-driver.sh | bash -s master -
```

### 3. Verification

#### a. Deploy StorageClass

```sh
kubectl apply -f storageclass-nfs.yaml
```

#### b. Deploy PersistentVolumeClaim

```sh
kubectl apply -f pvc-nfs-csi-dynamic.yaml
```

#### c. Deploy Pod

```sh
kubectl apply -f nginx-pod-nfs.yaml
```

### 4. Deploy VolumeSnapshotClass

```sh
kubectl apply -f snapshotclass.yaml
```

### 5. Create Snapshot and Restore

```sh
kubectl apply -f snapshot-nfs-dynamic.yaml
kubectl apply -f pvc-nfs-snapshot-restored.yaml
kubectl apply -f nginx-pod-restored-snapshot.yaml
```

## References

- [NFS Provisioner Example](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/deploy/example/nfs-provisioner/README.md)
- [Install CSI Driver (master)](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/docs/install-csi-driver-master.md)
- [Snapshot Example](https://github.com/kubernetes-csi/csi-driver-nfs/tree/master/deploy/example/snapshot)
