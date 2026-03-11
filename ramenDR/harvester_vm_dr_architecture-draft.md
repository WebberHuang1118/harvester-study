# Harvester VM Disaster Recovery Runbook with RamenDR, OCM, VolSync, and Longhorn

## Purpose

This document provides a full end-to-end runbook for building a VM disaster recovery lab with:

* 1 Ubuntu VM as the hub cluster running RKE2
* 2 Harvester clusters:

  * `harv` as the initial primary cluster
  * `marv` as the initial secondary cluster
* RamenDR for disaster recovery orchestration
* Open Cluster Management (OCM) for multi-cluster application placement
* VolSync for PVC data replication
* Longhorn as the storage backend
* KubeVirt / Harvester VM as the protected workload

This runbook covers:

* Architecture
* Control flow
* Storage flow
* Full commands
* Required YAML files
* Failover and failback flow
* Automatic VM failover design
* Validation and debugging checkpoints

---

# 1. High-Level Architecture

## 1.1 Overall Architecture

```text
                           +------------------------------------+
                           |            Hub Cluster             |
                           |         Ubuntu VM + RKE2           |
                           |                                    |
                           |  OCM Hub Controllers               |
                           |  - Placement Controller            |
                           |  - Subscription Controller         |
                           |                                    |
                           |  Ramen Hub Controller              |
                           |                                    |
                           |  Resources on Hub:                 |
                           |  - DRCluster                       |
                           |  - DRPolicy                        |
                           |  - DRPlacementControl              |
                           |  - PlacementRule                   |
                           |  - Channel                         |
                           |  - Subscription                    |
                           +-----------------+------------------+
                                             |
                                             | control plane
                                             |
                    +------------------------+------------------------+
                    |                                                 |
                    |                                                 |
        +-----------v------------+                         +----------v-------------+
        |  Harvester Cluster     |                         |  Harvester Cluster     |
        |  harv                  |                         |  marv                  |
        |  Initial Primary       |                         |  Initial Secondary     |
        |                        |                         |                        |
        |  VM manifests          |                         |  standby target        |
        |  Secret                |                         |                        |
        |  cloud-init            |                         |                        |
        |                        |                         |                        |
        |  VM running            |                         |  VM deployed after     |
        |  PVC RW                |                         |  placement switch      |
        |                        |                         |  PVC replicated        |
        |  VolSync Source        | ---- data replication ->|  VolSync Destination   |
        |  Longhorn              |                         |  Longhorn              |
        +------------------------+                         +------------------------+
```

## 1.2 Control Plane vs Data Plane

```text
+------------------------------------------------------------------+
| Application / Control Plane                                      |
|                                                                  |
| Git repository                                                   |
|   -> apps/vm-dr/                                                 |
|      - namespace.yaml                                            |
|      - vm.yaml                                                   |
|      - ssh-secret.yaml                                           |
|      - cloudinit-userdata.yaml                                   |
|      - cloudinit-networkdata.yaml                                |
|                                                                  |
| OCM Channel + Subscription + PlacementRule                       |
|   -> decides where the VM app manifests are deployed             |
+------------------------------------------------------------------+

+------------------------------------------------------------------+
| Storage / Data Plane                                             |
|                                                                  |
| Primary PVC on harv                                              |
|   -> Longhorn volume                                             |
|   -> snapshot                                                    |
|   -> VolSync replication                                         |
|   -> Secondary PVC on marv                                       |
|                                                                  |
| Ramen DRPlacementControl + DRPolicy                              |
|   -> orchestrates failover and relocate                          |
+------------------------------------------------------------------+
```

---

# 2. Design Principles

## 2.1 What OCM Handles

OCM handles application placement. In this design, OCM is responsible for:

* Namespace
* VirtualMachine manifest
* Secrets
* cloud-init manifests
* other non-PVC application resources

## 2.2 What Ramen + VolSync Handle

Ramen and VolSync handle PVC-based storage protection. In this design, they are responsible for:

* Selecting protected PVCs by `pvcSelector`
* Creating replication source and destination
* Performing final sync during failover
* Promoting the secondary PVC
* Coordinating storage failover

## 2.3 Important Rule

Do not put the VM data PVC manifest inside the Git repository managed by OCM Subscription.

Why:

* The PVC should be created only once on the initial primary cluster
* Afterwards it is replicated by VolSync
* If the Git app also creates the PVC on the secondary cluster, it can conflict with the replicated PVC

---

# 3. Expected Failover Behavior

## 3.1 Initial State

* `PlacementRule` selects `harv`
* OCM Subscription deploys VM app manifests to `harv`
* VM runs on `harv`
* `vm-disk` exists on `harv`
* VolSync replicates `vm-disk` from `harv` to `marv`

## 3.2 Failover State

After failover to `marv`:

* Ramen stops writes on the primary side
* VolSync performs final replication
* Secondary PVC on `marv` is promoted
* `PlacementRule` switches from `harv` to `marv`
* OCM Subscription deploys the VM manifests to `marv`
* Because the VM uses `runStrategy: Always`, the VM starts automatically on `marv`

## 3.3 Failback State

After relocate/failback to `harv`:

* Final sync runs from `marv` back to `harv`
* `harv` PVC becomes primary again
* `PlacementRule` switches back to `harv`
* OCM Subscription redeploys the VM app to `harv`
* The VM starts automatically on `harv`

---

# 4. Prerequisites

You need:

* 1 Ubuntu VM for the hub cluster
* 2 ready Harvester clusters
* Network connectivity between:

  * Ubuntu hub and both Harvester clusters
  * harv and marv for VolSync / replication path
* Access to a container registry for the Ramen operator image
* Kubeconfig files for:

  * hub cluster
  * harv
  * marv

Suggested environment variables:

```bash
export KUBECONFIG_HUB=~/.kube/config
export KUBECONFIG_HARV=~/kubeconfigs/harv.yaml
export KUBECONFIG_MARV=~/kubeconfigs/marv.yaml
export HUB_API=https://<HUB_IP>:6443
export REGISTRY=<your-registry>
```

---

# 5. Build the Hub Cluster on Ubuntu

## 5.1 Install RKE2

```bash
curl -sfL https://get.rke2.io | sudo sh -

sudo systemctl enable rke2-server
sudo systemctl start rke2-server
```

## 5.2 Copy the kubeconfig

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

## 5.3 Verify the hub cluster

```bash
export KUBECONFIG=$KUBECONFIG_HUB
kubectl get nodes -o wide
```

Meaning:

* This creates the Kubernetes hub cluster
* The hub cluster will host OCM and Ramen controllers

---

# 6. Install OCM on the Hub

## 6.1 Install clusteradm

```bash
curl -L https://raw.githubusercontent.com/open-cluster-management-io/clusteradm/main/install.sh | bash
clusteradm version
```

## 6.2 Initialize the OCM hub

```bash
export KUBECONFIG=$KUBECONFIG_HUB
clusteradm init --wait
```

## 6.3 Get the join token

```bash
clusteradm get token
```

Save the token value.

Meaning:

* `clusteradm init` installs OCM hub components
* `clusteradm get token` generates the token used by managed clusters to join the hub

---

# 7. Join the Harvester Clusters to the Hub

## 7.1 Join `harv`

```bash
export KUBECONFIG=$KUBECONFIG_HARV

clusteradm join \
  --hub-token <TOKEN> \
  --hub-apiserver $HUB_API \
  --cluster-name harv \
  --wait
```

## 7.2 Join `marv`

```bash
export KUBECONFIG=$KUBECONFIG_MARV

clusteradm join \
  --hub-token <TOKEN> \
  --hub-apiserver $HUB_API \
  --cluster-name marv \
  --wait
```

## 7.3 Accept the managed clusters on the hub

```bash
export KUBECONFIG=$KUBECONFIG_HUB
clusteradm accept --clusters harv,marv
kubectl get managedclusters
```

If needed, approve pending CSRs:

```bash
kubectl get csr
kubectl certificate approve <csr-name>
```

Meaning:

* `join` installs the managed cluster agents
* `accept` approves the managed cluster registration
* The hub can now manage `harv` and `marv`

---

# 8. Build and Deploy the Ramen Hub Operator

## 8.1 Clone the Ramen repository

```bash
git clone -b ramen_rke2_longhorn https://github.com/dstanley/ramen.git
cd ramen
```

## 8.2 Build and push the operator image

```bash
docker buildx build --platform linux/amd64 -t $REGISTRY/ramen-operator:dev --load .
docker push $REGISTRY/ramen-operator:dev
```

## 8.3 Deploy the hub operator

```bash
export KUBECONFIG=$KUBECONFIG_HUB
make deploy-hub IMG=$REGISTRY/ramen-operator:dev PLATFORM=k8s
kubectl get pods -n ramen-system
```

Meaning:

* This installs the Ramen hub controller on the Ubuntu RKE2 cluster
* The hub controller orchestrates DR workflows

---

# 9. Deploy MinIO for Ramen Metadata

## 9.1 Create `minio.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: minio-system
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
  namespace: minio-system
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: harvester-longhorn
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: minio/minio
          args:
            - server
            - /data
          env:
            - name: MINIO_ROOT_USER
              value: minioadmin
            - name: MINIO_ROOT_PASSWORD
              value: minioadmin
          ports:
            - containerPort: 9000
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-data
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio-system
spec:
  selector:
    app: minio
  ports:
    - port: 9000
      targetPort: 9000
```

## 9.2 Apply MinIO

```bash
export KUBECONFIG=$KUBECONFIG_HUB
kubectl apply -f minio.yaml
kubectl get pods -n minio-system
kubectl get svc -n minio-system
```

## 9.3 Create the bucket

```bash
kubectl -n minio-system run mc --rm -it --restart=Never \
  --image=minio/mc \
  --command -- /bin/sh -c \
  "mc alias set myminio http://minio.minio-system.svc.cluster.local:9000 minioadmin minioadmin && mc mb --ignore-existing myminio/ramen"
```

Meaning:

* Ramen needs an S3-compatible object store for metadata
* MinIO provides that for the lab

---

# 10. Configure the Ramen Hub Operator

## 10.1 Create the S3 secret

```bash
export KUBECONFIG=$KUBECONFIG_HUB

kubectl create secret generic s3-secret \
  -n ramen-system \
  --from-literal=AWS_ACCESS_KEY_ID=minioadmin \
  --from-literal=AWS_SECRET_ACCESS_KEY=minioadmin
```

## 10.2 Create `dr_hub_config.yaml`

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: RamenConfig
leaderElection:
  leaderElect: true
  resourceName: hub.ramendr.openshift.io
metrics:
  bindAddress: 127.0.0.1:9289
health:
  healthProbeBindAddress: :8081
webhook:
  port: 9443
ramenControllerType: dr-hub
maxConcurrentReconciles: 50
s3StoreProfiles:
  - s3ProfileName: minio-on-hub
    s3Bucket: ramen
    s3CompatibleEndpoint: http://minio.minio-system.svc.cluster.local:9000
    s3Region: us-east-1
    s3SecretRef:
      name: s3-secret
      namespace: ramen-system
```

## 10.3 Create the configmap

```bash
kubectl create configmap ramen-hub-operator-config \
  -n ramen-system \
  --from-file=ramen_manager_config.yaml=dr_hub_config.yaml
```

## 10.4 Restart the hub operator

```bash
kubectl rollout restart deployment -n ramen-system ramen-hub-operator
kubectl logs -n ramen-system deployment/ramen-hub-operator -c manager --tail=50
```

Meaning:

* This tells the hub operator to run in `dr-hub` mode
* It also tells it to use MinIO as the S3 metadata backend

---

# 11. Install the Ramen DR Cluster Operator on Both Harvester Clusters

## 11.1 On `harv`

```bash
export KUBECONFIG=$KUBECONFIG_HARV
cd ~/ramen
make deploy-dr-cluster IMG=$REGISTRY/ramen-operator:dev PLATFORM=k8s
kubectl get pods -n ramen-system
```

## 11.2 On `marv`

```bash
export KUBECONFIG=$KUBECONFIG_MARV
cd ~/ramen
make deploy-dr-cluster IMG=$REGISTRY/ramen-operator:dev PLATFORM=k8s
kubectl get pods -n ramen-system
```

Meaning:

* These controllers run on the managed clusters
* They participate in DR operations coordinated by the hub

---

# 12. Install VolSync on Both Harvester Clusters

```bash
helm repo add backube https://backube.github.io/helm-charts/
helm repo update
```

## 12.1 On `harv`

```bash
helm --kubeconfig $KUBECONFIG_HARV install volsync backube/volsync \
  -n volsync-system --create-namespace
```

## 12.2 On `marv`

```bash
helm --kubeconfig $KUBECONFIG_MARV install volsync backube/volsync \
  -n volsync-system --create-namespace
```

Meaning:

* VolSync performs the actual PVC data replication

---

# 13. Label Longhorn for Async DR

Important: use different `storageid` values for `harv` and `marv`.

## 13.1 On `harv`

```bash
kubectl --kubeconfig $KUBECONFIG_HARV label storageclass harvester-longhorn \
  ramendr.openshift.io/storageid=longhorn-harv --overwrite

kubectl --kubeconfig $KUBECONFIG_HARV label volumesnapshotclass longhorn-snapshot \
  ramendr.openshift.io/storageid=longhorn-harv --overwrite
```

## 13.2 On `marv`

```bash
kubectl --kubeconfig $KUBECONFIG_MARV label storageclass harvester-longhorn \
  ramendr.openshift.io/storageid=longhorn-marv --overwrite

kubectl --kubeconfig $KUBECONFIG_MARV label volumesnapshotclass longhorn-snapshot \
  ramendr.openshift.io/storageid=longhorn-marv --overwrite
```

Meaning:

* Different `storageid` values tell Ramen to treat this as async VolSync-based DR
* `longhorn-snapshot` is used for snapshot support

---

# 14. Create DRCluster and DRPolicy on the Hub

## 14.1 `drcluster.yaml`

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRCluster
metadata:
  name: harv
spec:
  s3ProfileName: minio-on-hub
  region: east
---
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRCluster
metadata:
  name: marv
spec:
  s3ProfileName: minio-on-hub
  region: west
```

## 14.2 `drpolicy.yaml`

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRPolicy
metadata:
  name: dr-policy
spec:
  drClusters:
    - harv
    - marv
  schedulingInterval: "5m"
```

## 14.3 Apply them

```bash
export KUBECONFIG=$KUBECONFIG_HUB
kubectl apply -f drcluster.yaml
kubectl apply -f drpolicy.yaml
kubectl get drcluster
kubectl get drpolicy
```

Meaning:

* `DRCluster` registers the DR participants for Ramen
* `DRPolicy` binds them into one DR pair with a 5-minute replication interval

---

# 15. Prepare the Git Repository for Automatic VM Deployment

## 15.1 Repository structure

```text
vm-dr-gitops/
└── apps/
    └── vm-dr/
        ├── 00-namespace.yaml
        ├── 01-vm-ssh-key.yaml
        ├── 02-vm-cloudinit-userdata.yaml
        ├── 03-vm-cloudinit-networkdata.yaml
        └── 04-vm.yaml
```

Only put non-PVC resources in this Git app.

---

# 16. YAML Files Stored in Git

## 16.1 `00-namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dr-test
```

## 16.2 `01-vm-ssh-key.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vm-ssh-key
  namespace: dr-test
type: Opaque
stringData:
  key1: |
    ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ...
```

## 16.3 `02-vm-cloudinit-userdata.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vm-cloudinit-userdata
  namespace: dr-test
type: Opaque
stringData:
  userdata: |
    #cloud-config
    users:
      - name: ubuntu
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        lock_passwd: true
    ssh_pwauth: false
```

## 16.4 `03-vm-cloudinit-networkdata.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vm-cloudinit-networkdata
  namespace: dr-test
type: Opaque
stringData:
  networkdata: |
    version: 2
    ethernets:
      eth0:
        dhcp4: true
```

## 16.5 `04-vm.yaml`

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-dr
  namespace: dr-test
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: vm-dr
    spec:
      accessCredentials:
        - sshPublicKey:
            source:
              secret:
                secretName: vm-ssh-key
            propagationMethod:
              noCloud: {}
      domain:
        cpu:
          cores: 2
        resources:
          requests:
            memory: 2Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          persistentVolumeClaim:
            claimName: vm-disk
        - name: cloudinitdisk
          cloudInitNoCloud:
            userDataSecretRef:
              name: vm-cloudinit-userdata
            networkDataSecretRef:
              name: vm-cloudinit-networkdata
```

Meaning:

* These files define the VM app
* OCM Subscription deploys them automatically to the currently selected cluster

---

# 17. Create the Primary PVC Only on `harv`

## 17.1 `vm-disk-pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm-disk
  namespace: dr-test
  labels:
    app: vm-dr-test
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: harvester-longhorn
  resources:
    requests:
      storage: 10Gi
```

## 17.2 Apply on `harv`

```bash
kubectl --kubeconfig $KUBECONFIG_HARV create namespace dr-test
kubectl --kubeconfig $KUBECONFIG_HARV apply -f vm-disk-pvc.yaml
kubectl --kubeconfig $KUBECONFIG_HARV get pvc -n dr-test
```

Meaning:

* This PVC is the VM disk
* It must match the `pvcSelector` label in DRPlacementControl
* It should be created only once on the initial primary cluster

---

# 18. Create OCM Application Delivery Resources on the Hub

## 18.1 Create a namespace for channels

`channel-ns.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dr-channels
```

## 18.2 Create the Git Channel

`git-channel.yaml`

```yaml
apiVersion: apps.open-cluster-management.io/v1
kind: Channel
metadata:
  name: vm-dr-git
  namespace: dr-channels
spec:
  type: Git
  pathname: https://github.com/<your-org>/<your-repo>.git
```

## 18.3 Create the PlacementRule

`placementrule.yaml`

```yaml
apiVersion: apps.open-cluster-management.io/v1
kind: PlacementRule
metadata:
  name: vm-placement
  namespace: dr-test
spec:
  clusterSelector:
    matchLabels:
      name: harv
```

Label the managed clusters first:

```bash
kubectl --kubeconfig $KUBECONFIG_HUB label managedcluster harv name=harv --overwrite
kubectl --kubeconfig $KUBECONFIG_HUB label managedcluster marv name=marv --overwrite
```

## 18.4 Create the Subscription

`subscription.yaml`

```yaml
apiVersion: apps.open-cluster-management.io/v1
kind: Subscription
metadata:
  name: vm-dr-sub
  namespace: dr-test
  annotations:
    apps.open-cluster-management.io/git-path: apps/vm-dr
    apps.open-cluster-management.io/git-branch: main
    apps.open-cluster-management.io/reconcile-option: merge
spec:
  channel: dr-channels/vm-dr-git
  placement:
    placementRef:
      kind: PlacementRule
      name: vm-placement
```

Meaning:

* `Channel` points to the Git repo
* `Subscription` deploys the files under `apps/vm-dr`
* `PlacementRule` selects which managed cluster gets the VM app

---

# 19. Create the DRPlacementControl on the Hub

## 19.1 `drpc.yaml`

```yaml
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRPlacementControl
metadata:
  name: vm-drpc
  namespace: dr-test
spec:
  drPolicyRef:
    name: dr-policy
  placementRef:
    kind: PlacementRule
    name: vm-placement
  pvcSelector:
    matchLabels:
      app: vm-dr-test
```

## 19.2 Apply all hub-side resources

```bash
export KUBECONFIG=$KUBECONFIG_HUB

kubectl create namespace dr-channels
kubectl create namespace dr-test

kubectl apply -f channel-ns.yaml
kubectl apply -f git-channel.yaml
kubectl apply -f placementrule.yaml
kubectl apply -f subscription.yaml
kubectl apply -f drpc.yaml
```

Meaning:

* `DRPlacementControl` protects the PVC in `dr-test`
* It uses the same `PlacementRule` as the OCM Subscription
* This is the key to automatic VM failover

---

# 20. Initial Validation

## 20.1 On the hub

```bash
kubectl --kubeconfig $KUBECONFIG_HUB get managedclusters
kubectl --kubeconfig $KUBECONFIG_HUB get drcluster
kubectl --kubeconfig $KUBECONFIG_HUB get drpolicy
kubectl --kubeconfig $KUBECONFIG_HUB get drplacementcontrol -n dr-test
kubectl --kubeconfig $KUBECONFIG_HUB get placementrule -n dr-test
kubectl --kubeconfig $KUBECONFIG_HUB get subscription -n dr-test
```

## 20.2 On `harv`

```bash
kubectl --kubeconfig $KUBECONFIG_HARV get vm,vmi,secret -n dr-test
kubectl --kubeconfig $KUBECONFIG_HARV get pvc -n dr-test
```

Expected:

* `vm-dr` exists on `harv`
* `vm-dr` is running
* `vm-disk` exists on `harv`

## 20.3 On `marv`

```bash
kubectl --kubeconfig $KUBECONFIG_MARV get vm,vmi,secret -n dr-test
kubectl --kubeconfig $KUBECONFIG_MARV get pvc -n dr-test
```

Expected:

* `vm-disk` replicated copy appears on `marv`
* VM app manifests will eventually land on the selected cluster according to the Subscription and placement behavior

---

# 21. Write Test Data to the Primary VM

Connect to the VM on `harv`:

```bash
virtctl --kubeconfig $KUBECONFIG_HARV console vm-dr -n dr-test
```

Inside the VM:

```bash
echo "auto-ramen-test" | sudo tee /data/test.txt
sync
```

Meaning:

* This creates validation data on the primary VM disk
* After failover, you will verify the same data on the secondary side

---

# 22. Trigger Automatic Failover

## 22.1 Fail over to `marv`

```bash
kubectl --kubeconfig $KUBECONFIG_HUB patch drplacementcontrol vm-drpc \
  -n dr-test \
  --type merge \
  -p '{"spec":{"action":"Failover","failoverCluster":"marv"}}'
```

## 22.2 Watch the DRPlacementControl

```bash
kubectl --kubeconfig $KUBECONFIG_HUB get drplacementcontrol vm-drpc -n dr-test -w
```

## 22.3 Watch the PlacementRule

```bash
kubectl --kubeconfig $KUBECONFIG_HUB get placementrule vm-placement -n dr-test -o yaml
```

Expected flow:

1. Ramen begins failover
2. Final sync completes
3. Secondary PVC is promoted
4. Placement changes from `harv` to `marv`
5. Subscription deploys VM app manifests to `marv`
6. VM starts automatically on `marv`

---

# 23. Validate the Secondary VM After Failover

## 23.1 Check the resources on `marv`

```bash
kubectl --kubeconfig $KUBECONFIG_MARV get vm,vmi,secret,pvc -n dr-test
```

Expected:

* The replicated `vm-disk` PVC is present and usable
* The VM manifests have been deployed to `marv`
* The VM is running on `marv`

## 23.2 Verify the data

```bash
virtctl --kubeconfig $KUBECONFIG_MARV console vm-dr -n dr-test
```

Inside the VM:

```bash
cat /data/test.txt
```

Expected output:

```text
auto-ramen-test
```

---

# 24. Trigger Failback / Relocate

## 24.1 Write one more file on `marv`

Inside the VM on `marv`:

```bash
echo "failback-auto-test" | sudo tee /data/test2.txt
sync
```

## 24.2 Relocate back to `harv`

```bash
kubectl --kubeconfig $KUBECONFIG_HUB patch drplacementcontrol vm-drpc \
  -n dr-test \
  --type merge \
  -p '{"spec":{"action":"Relocate","preferredCluster":"harv"}}'
```

## 24.3 Validate on `harv`

```bash
kubectl --kubeconfig $KUBECONFIG_HARV get vm,vmi,pvc -n dr-test
virtctl --kubeconfig $KUBECONFIG_HARV console vm-dr -n dr-test
```

Inside the VM:

```bash
cat /data/test.txt
cat /data/test2.txt
```

Expected:

* Both files exist after failback

---

# 25. Controller-Level Flow Diagram

## 25.1 Normal Operation

```text
[Git repo contains VM app manifests]
              |
              v
[OCM Subscription reads apps/vm-dr]
              |
              v
[PlacementRule currently selects harv]
              |
              v
[OCM deploys VM / Secret / cloud-init to harv]
              |
              v
[VM starts on harv]

Meanwhile:

[DRPlacementControl]
        |
        v
[Ramen Hub Controller]
        |
        v
[Create VolSync source and destination]
        |
        v
[Longhorn PVC on harv replicates to marv]
```

## 25.2 Failover Flow

```text
[User patches DRPlacementControl: Failover to marv]
                      |
                      v
             [Ramen Hub Controller]
                      |
          +-----------+-----------+
          |                       |
          v                       v
[Stop writes / workload]   [Request final replication]
          |                       |
          v                       v
[Final sync completes]     [Secondary PVC is current]
          |                       |
          +-----------+-----------+
                      v
           [Promote secondary PVC]
                      |
                      v
         [PlacementRule changes to marv]
                      |
                      v
[OCM Subscription deploys VM app to marv]
                      |
                      v
 [VM starts automatically on marv]
```

## 25.3 Failback Flow

```text
[User patches DRPlacementControl: Relocate to harv]
                      |
                      v
             [Ramen Hub Controller]
                      |
                      v
         [Final sync from marv to harv]
                      |
                      v
           [Promote harv PVC to primary]
                      |
                      v
         [PlacementRule changes back to harv]
                      |
                      v
[OCM Subscription deploys VM app back to harv]
                      |
                      v
 [VM starts automatically on harv]
```

---

# 26. Responsibility Matrix

| Component                | Responsibility                                         |
| ------------------------ | ------------------------------------------------------ |
| OCM PlacementRule        | Decides which cluster should host the VM app           |
| OCM Subscription         | Deploys VM manifests from Git to the selected cluster  |
| Ramen DRPlacementControl | Drives DR orchestration and failover/relocate workflow |
| VolSync                  | Replicates PVC data                                    |
| Longhorn                 | Provides storage and snapshots                         |
| KubeVirt / Harvester     | Runs the VM workload                                   |

---

# 27. Validation and Debug Commands

## 27.1 Hub-side checks

```bash
kubectl --kubeconfig $KUBECONFIG_HUB get drplacementcontrol -n dr-test -o yaml
kubectl --kubeconfig $KUBECONFIG_HUB get placementrule -n dr-test -o yaml
kubectl --kubeconfig $KUBECONFIG_HUB get subscription -n dr-test -o yaml
kubectl --kubeconfig $KUBECONFIG_HUB get drcluster -o yaml
kubectl --kubeconfig $KUBECONFIG_HUB get drpolicy -o yaml
```

## 27.2 Primary cluster checks

```bash
kubectl --kubeconfig $KUBECONFIG_HARV get vm,vmi,pvc,secret -n dr-test
kubectl --kubeconfig $KUBECONFIG_HARV get replicationsource -A
kubectl --kubeconfig $KUBECONFIG_HARV logs -n volsync-system deploy/volsync-controller-manager
```

## 27.3 Secondary cluster checks

```bash
kubectl --kubeconfig $KUBECONFIG_MARV get vm,vmi,pvc,secret -n dr-test
kubectl --kubeconfig $KUBECONFIG_MARV get replicationdestination -A
kubectl --kubeconfig $KUBECONFIG_MARV logs -n volsync-system deploy/volsync-controller-manager
```

## 27.4 Common checkpoints

Check whether:

* `PlacementRule` points to the expected cluster
* `Subscription` has reconciled successfully
* `ReplicationSource` and `ReplicationDestination` exist
* The secondary PVC exists before failover completes
* The VM manifests exist on the target cluster
* The VM is running on the target cluster

---

# 28. Important Notes

## 28.1 VM manifests do not need the PVC selector label

Only the protected PVC needs the label used by `pvcSelector`.

Example:

```yaml
metadata:
  labels:
    app: vm-dr-test
```

This label is required on the PVC, not on the VM manifest.

## 28.2 Secrets and cloud-init are not selected by `pvcSelector`

They are moved by OCM Subscription because they are part of the application manifest bundle.

## 28.3 `DRPlacementControl` namespace defines the application DR scope

Because `DRPlacementControl` is created in `dr-test`, that namespace is the application DR boundary.

---

# 29. Summary

This design achieves fully automatic VM failover by combining:

* OCM for application placement
* Ramen for DR orchestration
* VolSync for PVC replication
* Longhorn for storage
* KubeVirt / Harvester for VM execution

The core idea is simple:

```text
OCM decides where the VM application should live
Ramen and VolSync ensure the VM disk data is available there
```

That is the recommended method discussed in this document.

---

# 30. Quick Reference Command Summary

## Hub setup

```bash
curl -sfL https://get.rke2.io | sudo sh -
sudo systemctl enable rke2-server
sudo systemctl start rke2-server

mkdir -p ~/.kube
sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config

curl -L https://raw.githubusercontent.com/open-cluster-management-io/clusteradm/main/install.sh | bash
clusteradm init --wait
clusteradm get token
```

## Join managed clusters

```bash
clusteradm join --hub-token <TOKEN> --hub-apiserver $HUB_API --cluster-name harv --wait
clusteradm join --hub-token <TOKEN> --hub-apiserver $HUB_API --cluster-name marv --wait
clusteradm accept --clusters harv,marv
```

## Deploy Ramen

```bash
git clone -b ramen_rke2_longhorn https://github.com/dstanley/ramen.git
cd ramen
docker buildx build --platform linux/amd64 -t $REGISTRY/ramen-operator:dev --load .
docker push $REGISTRY/ramen-operator:dev

make deploy-hub IMG=$REGISTRY/ramen-operator:dev PLATFORM=k8s
make deploy-dr-cluster IMG=$REGISTRY/ramen-operator:dev PLATFORM=k8s
```

## Deploy VolSync

```bash
helm repo add backube https://backube.github.io/helm-charts/
helm repo update
helm --kubeconfig $KUBECONFIG_HARV install volsync backube/volsync -n volsync-system --create-namespace
helm --kubeconfig $KUBECONFIG_MARV install volsync backube/volsync -n volsync-system --create-namespace
```

## Protect storage

```bash
kubectl --kubeconfig $KUBECONFIG_HARV apply -f vm-disk-pvc.yaml
kubectl --kubeconfig $KUBECONFIG_HUB apply -f drcluster.yaml
kubectl --kubeconfig $KUBECONFIG_HUB apply -f drpolicy.yaml
kubectl --kubeconfig $KUBECONFIG_HUB apply -f drpc.yaml
```

## Deploy VM app automatically

```bash
kubectl --kubeconfig $KUBECONFIG_HUB apply -f channel-ns.yaml
kubectl --kubeconfig $KUBECONFIG_HUB apply -f git-channel.yaml
kubectl --kubeconfig $KUBECONFIG_HUB apply -f placementrule.yaml
kubectl --kubeconfig $KUBECONFIG_HUB apply -f subscription.yaml
```

## Failover

```bash
kubectl --kubeconfig $KUBECONFIG_HUB patch drplacementcontrol vm-drpc \
  -n dr-test \
  --type merge \
  -p '{"spec":{"action":"Failover","failoverCluster":"marv"}}'
```

## Failback

```bash
kubectl --kubeconfig $KUBECONFIG_HUB patch drplacementcontrol vm-drpc \
  -n dr-test \
  --type merge \
  -p '{"spec":{"action":"Relocate","preferredCluster":"harv"}}'
```
