# Longhorn RWX NFS Proxy on Harvester Storage Network

This guide documents a working approach for exposing a Longhorn RWX share-manager to a KubeVirt VM that can only access the storage network (`172.16.0.0/24`) and cannot access the pod network or ClusterIP network directly.

The approach uses:

- a **headless Service** to track the current share-manager Pod IP
- an **HAProxy Pod** with:
  - a normal pod-network interface for reaching Kubernetes DNS and the headless Service backend
  - a storage-network secondary interface with a **fixed IP** for the VM to mount

In the example below:

- Storage network NAD: `harvester-system/storagenetwork-kpzn5`
- Fixed proxy IP: `172.16.0.210`
- PVC / share-manager identifier: `pvc-d3fad61a-5e8b-44cf-af76-1ac52724dc01`
- Namespace: `longhorn-system`

---

## Important behavior notes

1. This solution gives the VM a **stable mount target IP** (`172.16.0.210`).
2. If the **share-manager Pod** is deleted and recreated, the mount can recover through the same proxy IP.
3. If the **proxy Pod** itself is recreated, the fixed IP can come back on the new Pod and the design still works.
4. **VM I/O can still stall for a while during recovery**. This is expected with NFS hard mounts and Longhorn RWX/share-manager failover behavior. The benefit of this design is that you do not need to change the VM mount target when the backend Pod changes.
5. This is not true zero-interruption HA. It is a practical way to keep a stable frontend IP on the storage network.

---

## Architecture

```text
VM (172.16.0.x)
    |
    |  mount 172.16.0.210:/pvc-d3fad61a-5e8b-44cf-af76-1ac52724dc01
    v
nfs-proxy Pod
  - eth0: pod network
  - net1: storage network, fixed IP 172.16.0.210
    |
    |  HAProxy TCP proxy
    v
Headless Service
    |
    v
Current Longhorn share-manager Pod IP
```

---

## Prerequisites

Before applying the manifests, make sure:

1. The storage network NAD already exists.
2. The proxy IP `172.16.0.210` is reserved and not used by other Pods or VMs.
3. The storage NAD supports static IP requests through the Multus `ips` capability.
4. The share-manager Pod is reachable from inside the cluster on TCP 2049.
5. The VM can reach `172.16.0.210` on the storage network.

Recommended: exclude `172.16.0.210/32` from the Whereabouts allocation pool to avoid accidental IP conflicts.

---

## Step 1 - Create the headless Service

Save as `lh-share-manager-headless.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: lh-share-manager-headless
  namespace: longhorn-system
spec:
  clusterIP: None
  selector:
    longhorn.io/share-manager: pvc-d3fad61a-5e8b-44cf-af76-1ac52724dc01
  ports:
  - name: nfs
    port: 2049
    targetPort: 2049
    protocol: TCP
```

Apply it:

```bash
kubectl apply -f lh-share-manager-headless.yaml
```

Verify it resolves to the current share-manager Pod IP:

```bash
kubectl -n longhorn-system get endpoints lh-share-manager-headless -o yaml
kubectl -n longhorn-system get endpointslice -l kubernetes.io/service-name=lh-share-manager-headless -o yaml
```

---

## Step 2 - Find the cluster DNS service IP

HAProxy needs to resolve the headless Service DNS name.

Find the CoreDNS / kube-dns ClusterIP:

```bash
kubectl -n kube-system get svc kube-dns
```

Example output:

```text
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.53.0.10   <none>        53/UDP,53/TCP,9153/TCP   ...
```

Use that ClusterIP in the HAProxy config below.

---

## Step 3 - Create the HAProxy ConfigMap

Save as `haproxy-cm.yaml`.

Replace `10.53.0.10` below with your actual `kube-dns` Service IP if it is different.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nfs-proxy-haproxy
  namespace: longhorn-system
data:
  haproxy.cfg: |
    global
      log stdout format raw local0
      maxconn 2000

    defaults
      mode tcp
      log global
      timeout connect 5s
      timeout client 1h
      timeout server 1h

    resolvers k8s
      nameserver dns1 10.53.0.10:53
      resolve_retries 30
      timeout retry 1s
      hold valid 1s

    frontend nfs_frontend
      bind 172.16.0.210:2049
      default_backend nfs_backend

    backend nfs_backend
      default-server inter 1s fall 2 rise 1 on-marked-down shutdown-sessions init-addr last,libc,none
      server-template sharemgr 1 lh-share-manager-headless.longhorn-system.svc.cluster.local:2049 resolvers k8s check
```

Apply it:

```bash
kubectl apply -f haproxy-cm.yaml
```

---

## Step 4 - Create the proxy Pod with fixed storage-network IP

Save as `nfs-proxy-pod.yaml`.

This Pod:

- runs HAProxy
- gets a normal pod-network interface automatically
- gets a storage-network secondary interface from `storagenetwork-kpzn5`
- requests a fixed storage IP: `172.16.0.210/24`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nfs-proxy
  namespace: longhorn-system
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [
        {
          "name": "storagenetwork-kpzn5",
          "namespace": "harvester-system",
          "ips": ["172.16.0.210/24"]
        }
      ]
spec:
  restartPolicy: Always
  containers:
  - name: haproxy
    image: haproxy:3.0
    imagePullPolicy: IfNotPresent
    ports:
    - containerPort: 2049
      protocol: TCP
    volumeMounts:
    - name: haproxy-config
      mountPath: /usr/local/etc/haproxy
  volumes:
  - name: haproxy-config
    configMap:
      name: nfs-proxy-haproxy
```

Apply it:

```bash
kubectl apply -f nfs-proxy-pod.yaml
```

Verify it:

```bash
kubectl -n longhorn-system get pod nfs-proxy -o wide
kubectl -n longhorn-system describe pod nfs-proxy
kubectl -n longhorn-system logs nfs-proxy
```

Optional debug check with an ephemeral debug container:

```bash
kubectl -n longhorn-system debug -it pod/nfs-proxy --target=haproxy --image=nicolaka/netshoot -- /bin/bash
```

Useful checks inside the debug shell:

```bash
ip addr
ip route
ss -lnt
nc -vz lh-share-manager-headless.longhorn-system.svc.cluster.local 2049
```

Expected behavior:

- `eth0` on pod network
- `net1` on storage network
- `172.16.0.210/24` present on `net1`
- HAProxy listening on `172.16.0.210:2049`
- backend connectivity to the headless Service DNS name succeeds

---

## Step 5 - Mount from the VM

From the KubeVirt VM on the storage network:

```bash
sudo arping 172.16.0.210
nc -vz 172.16.0.210 2049
sudo mount -t nfs -o vers=4.2,hard,timeo=100,retrans=2 172.16.0.210:/pvc-d3fad61a-5e8b-44cf-af76-1ac52724dc01 /mnt
```

Validate:

```bash
df -h
touch /mnt/testing
echo "testing" > /mnt/testing
cat /mnt/testing
```

---

## Step 6 - Failover / restart test

### Test A - Recreate the share-manager Pod

Delete the current share-manager Pod:

```bash
kubectl -n longhorn-system get pod -o wide | grep share-manager
kubectl -n longhorn-system delete pod <share-manager-pod-name>
```

Watch the endpoint move to the new Pod:

```bash
kubectl -n longhorn-system get endpoints lh-share-manager-headless -w
kubectl -n longhorn-system get pod -o wide -w
```

Notes:

- During this time, VM I/O on the mounted directory can stall.
- With a hard NFS mount, operations may block for a while before recovering.
- The mount target on the VM stays the same: `172.16.0.210`.

### Test B - Recreate the proxy Pod

Delete the proxy Pod:

```bash
kubectl -n longhorn-system delete pod nfs-proxy
```

Watch it come back:

```bash
kubectl -n longhorn-system get pod nfs-proxy -w
```

Notes:

- The fixed storage-network IP can come back on the recreated proxy Pod.
- VM I/O can still stall for some time while the proxy Pod is recreated and the TCP/NFS session is re-established.
- This is expected for hard NFS mounts and long-lived TCP connections.

---

## Troubleshooting

### 1. VM can ARP the IP but cannot connect to port 2049

Check inside the proxy Pod:

```bash
kubectl -n longhorn-system logs nfs-proxy
kubectl -n longhorn-system debug -it pod/nfs-proxy --target=haproxy --image=nicolaka/netshoot -- /bin/bash
ss -lnt
```

### 2. Proxy Pod can resolve DNS but backend still fails

Check the headless Service endpoints:

```bash
kubectl -n longhorn-system get endpoints lh-share-manager-headless -o yaml
kubectl -n longhorn-system get endpointslice -l kubernetes.io/service-name=lh-share-manager-headless -o yaml
```

### 3. Another Pod accidentally gets 172.16.0.210

Reserve or exclude that IP from the Whereabouts pool if possible.

### 4. VM I/O hangs for a while after failover

This is expected to some degree with NFS hard mounts and Longhorn RWX/share-manager restart behavior. The design keeps a stable frontend IP, but it is not true zero-interruption failover.

---

## Summary

This design is useful when:

- the VM can only access the storage network
- the VM cannot use cluster DNS directly
- the VM cannot reach pod or ClusterIP networks directly
- you want a stable IP for the NFS mount target
- you do not want to change node network settings or use MetalLB

The key benefits are:

- stable frontend IP on the storage network
- no need to remount to a new Pod IP after share-manager recreation
- practical and relatively self-contained setup

The key limitation is:

- backend restarts or proxy restarts can still cause the VM I/O to block for a while, especially with `hard` NFS mounts

