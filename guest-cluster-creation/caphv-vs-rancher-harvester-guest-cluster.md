# CAPHV vs Rancher Harvester Guest Cluster Provisioning

Date: 2026-06-30

This note summarizes our discussion about `cluster-api-provider-harvester` (CAPHV) and how guest clusters are usually created from Rancher when using Harvester as the provider.

## 1. What is CAPHV?

`cluster-api-provider-harvester`, also called **CAPHV**, is a **Cluster API infrastructure provider** for Harvester.

Its purpose is to let a management Kubernetes cluster use **Cluster API (CAPI)** to create Kubernetes/RKE2 clusters whose nodes are **VMs running on Harvester**.

Conceptually:

```text
Management cluster
  ├─ CAPI core controller
  ├─ bootstrap/control-plane providers
  └─ CAPHV controller
        ↓
Harvester cluster
  ├─ create VMs
  ├─ attach VM images / disks
  ├─ configure networks / IPs
  ├─ inject cloud-init
  └─ bootstrap those VMs into a Kubernetes/RKE2 cluster
```

CAPHV is not mainly for installing Harvester itself. It is for creating and lifecycle-managing guest Kubernetes clusters on top of Harvester VMs through CAPI.

Typical CAPHV resources include:

```text
HarvesterCluster
HarvesterMachine
HarvesterMachineTemplate
```

## 2. Important distinction


**the common Rancher UI flow for creating an RKE2/K3s cluster on Harvester is usually not CAPHV**.

There are two different routes:

```text
Route A: Rancher UI Harvester provider
  → Rancher provisioning
  → rancher/machine
  → docker-machine-driver-harvester
  → Harvester / KubeVirt VM

Route B: Native CAPI / Rancher Turtles style
  → CAPI Cluster
  → HarvesterCluster / HarvesterMachine
  → CAPHV controller
  → Harvester / KubeVirt VM
```

So when someone says "Rancher creates a guest cluster on Harvester", we need to clarify which path is being used.

## 3. Classic Rancher UI route

If you create a guest cluster from Rancher UI and select **Harvester** as the provider, the normal route is usually:

```text
Rancher UI
  ↓
provisioning.cattle.io Cluster
  ↓
Rancher provisioning controllers
  ↓
Rancher RKE2/K3s bootstrap/control-plane logic
  ↓
Rancher machine provisioning
  ↓
rancher/machine
  ↓
docker-machine-driver-harvester
  ↓
Harvester Kubernetes API
  ↓
KubeVirt VirtualMachine objects
  ↓
VM boots with cloud-init
  ↓
rancher-system-agent installs/configures RKE2
  ↓
VM joins the guest cluster as a Kubernetes node
```

In this path, the VM is created by the **Harvester node driver**, implemented by `docker-machine-driver-harvester`.

## 4. How the node VM is created

The node-driver route roughly works like this:

```text
Rancher management cluster
  ↓
Machine provisioning controller
  ↓
rancher-machine / docker-machine flow
  ↓
docker-machine-driver-harvester
  ↓
uses Harvester cloud credential / kubeconfig / token
  ↓
calls Harvester Kubernetes API
  ↓
creates KubeVirt VirtualMachine object
  ↓
Harvester/KubeVirt creates VirtualMachineInstance and virt-launcher pod
  ↓
VM boots from selected cloud image
  ↓
cloud-init runs
  ↓
rancher-system-agent starts
  ↓
RKE2/K3s is installed and configured
  ↓
node joins guest cluster
```

So the actual VM object is created inside the Harvester cluster as a KubeVirt `VirtualMachine`.

The selected Harvester options from Rancher UI, such as image, namespace, CPU, memory, disk, network, SSH user, and cloud-init-related settings, are passed down into the Harvester machine config and then used by the node driver.

## 5. How the VMs compose the guest cluster

Each Rancher-created Harvester VM becomes one node in the downstream/guest cluster.

For example:

```text
Guest cluster: demo-rke2

Control plane node pool:
  demo-rke2-cp-1  → Harvester VM
  demo-rke2-cp-2  → Harvester VM
  demo-rke2-cp-3  → Harvester VM

Worker node pool:
  demo-rke2-worker-1 → Harvester VM
  demo-rke2-worker-2 → Harvester VM
```

The VMs compose the guest cluster through Rancher's RKE2/K3s bootstrap flow:

```text
First control-plane VM
  → initializes RKE2 server / etcd

Additional control-plane VMs
  → join existing RKE2 server / etcd cluster

Worker VMs
  → join as RKE2 agents

Rancher management cluster
  → tracks desired state and actual Machine state
```

## 6. CAPHV route

If CAPHV is explicitly installed and used, the route is different:

```text
CAPI Cluster
  ↓
HarvesterCluster
  ↓
HarvesterMachineTemplate
  ↓
HarvesterMachine
  ↓
CAPHV controller
  ↓
Harvester API
  ↓
KubeVirt VirtualMachine
  ↓
VM bootstraps into Kubernetes/RKE2 node
```

In this route, the CAPHV controller reconciles CAPI infrastructure resources and creates Harvester/KubeVirt VM resources.

This is closer to the upstream CAPI model:

```text
Cluster API Cluster
  ├─ ControlPlane provider
  ├─ Bootstrap provider
  └─ Infrastructure provider: CAPHV
```

## 7. How to check which route your Rancher cluster used

On the Rancher management/local cluster, check these resources.

### Rancher provisioning objects

```bash
kubectl get clusters.provisioning.cattle.io -A
```

### CAPI-style objects used by Rancher provisioning

```bash
kubectl get clusters.cluster.x-k8s.io -A
kubectl get machinedeployments.cluster.x-k8s.io -A
kubectl get machines.cluster.x-k8s.io -A
```

### Classic Rancher Harvester node-driver resources

```bash
kubectl get harvesterconfigs.rke-machine-config.cattle.io -A
kubectl get harvestermachines.rke-machine.cattle.io -A
kubectl get harvestermachinetemplates.rke-machine.cattle.io -A
```

If you see resources such as:

```text
harvesterconfigs.rke-machine-config.cattle.io
harvestermachines.rke-machine.cattle.io
harvestermachinetemplates.rke-machine.cattle.io
```

then the cluster is using the **Rancher machine / Harvester node-driver path**, not the CAPHV path.

### CAPHV resources

If CAPHV is used, you should expect resources like:

```bash
kubectl get harvesterclusters.infrastructure.cluster.x-k8s.io -A
kubectl get harvestermachines.infrastructure.cluster.x-k8s.io -A
kubectl get harvestermachinetemplates.infrastructure.cluster.x-k8s.io -A
```

Resource names may vary slightly depending on CAPHV version, so checking installed CRDs is useful:

```bash
kubectl get crd | grep -i harvester
kubectl get crd | grep -i cluster.x-k8s.io
```

## 8. How to check the created VMs on Harvester

On the Harvester cluster:

```bash
kubectl get vm -A | grep <guest-cluster-name>
kubectl get vmi -A | grep <guest-cluster-name>
kubectl get pods -A | grep virt-launcher | grep <guest-cluster-name>
```

You can also inspect a specific VM:

```bash
kubectl get vm -n <namespace> <vm-name> -o yaml
kubectl get vmi -n <namespace> <vmi-name> -o yaml
```

The VM should show disks, networks, cloud-init references, and KubeVirt-related state.

## 9. Practical conclusion

The short version:

```text
Rancher UI "Create RKE2/K3s cluster on Harvester"
  usually means:
    Rancher provisioning
    + rancher/machine
    + docker-machine-driver-harvester
    + Harvester/KubeVirt VM

CAPHV
  means:
    Native Cluster API infrastructure provider for Harvester
    + HarvesterCluster / HarvesterMachine resources
    + CAPHV controller
    + Harvester/KubeVirt VM
```

## 10. References

- CAPHV repository: <https://github.com/rancher-sandbox/cluster-api-provider-harvester>
- Harvester node driver documentation: <https://docs.harvesterhci.io/v1.8/rancher/node/node-driver>
- Harvester RKE2 cluster creation documentation: <https://docs.harvesterhci.io/v1.8/rancher/node/rke2-cluster>
- Harvester docker machine driver: <https://github.com/harvester/docker-machine-driver-harvester>
- Rancher CAPI infrastructure provider documentation: <https://ranchermanager.docs.rancher.com/how-to-guides/advanced-user-guides/capi-infrastructure-providers>
