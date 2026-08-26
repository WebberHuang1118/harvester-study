# Dual-Stack, IP Family Ordering, and Longhorn

## Summary

- **Dual-stack** means that a cluster enables IPv4 and IPv6 at the same time. A typical dual-stack Pod receives one IPv4 address and one IPv6 address.
- **IPv4-first** and **IPv6-first** describe address-family ordering and the primary/default family. They do not mean that the other family is unavailable.
- RKE2 uses the CIDR order in `cluster-cidr` and `service-cidr` to define the cluster's primary family. Dual-stack must be configured when the cluster is created.
- Longhorn v1.12 supports IPv4-first and IPv6-first dual-stack clusters, provided that all nodes use the same family ordering.
- Longhorn v1.12 does not provide a global setting that explicitly forces all backend data-plane traffic to use IPv4 or IPv6. Existing behavior generally follows the primary Pod/network family or legacy address-selection logic.
- [Longhorn issue #13050](https://github.com/longhorn/longhorn/issues/13050) is adding `data-engine-ip-family`, which will allow the Longhorn backend data plane and backing-image traffic to explicitly select `ipv4` or `ipv6`. As of the verification date, this work is still in progress and targets the v1.13.0 milestone.

## 1. What Is Dual-Stack?

IP has two address families:

- IPv4, for example `10.42.1.15`
- IPv6, for example `fd42::15`

A single-stack cluster enables only one family. A dual-stack cluster enables both IPv4 and IPv6. Kubernetes dual-stack can provide:

- An IPv4 and an IPv6 address for each Pod.
- Services that use IPv4, IPv6, or both.
- Off-cluster egress over IPv4 and IPv6, provided that the CNI, routing, and external network also support both families.

A Pod may have the following status:

```yaml
status:
  podIP: 10.42.1.15
  podIPs:
    - ip: 10.42.1.15
    - ip: fd42::15
```

`podIPs` contains both families. `podIP` and `podIPs[0]` represent the primary Pod IP. An application that reads only `podIP` or `podIPs[0]` still selects only one family.

Reference: [Kubernetes IPv4/IPv6 dual-stack](https://kubernetes.io/docs/concepts/services-networking/dual-stack/)

## 2. IPv4-First and IPv6-First

The word "first" describes primary/default ordering. It does not mean that only that family is enabled.

| Mode | Pod/CIDR order example | Primary family | Secondary family |
| --- | --- | --- | --- |
| IPv4-first | `IPv4, IPv6` | IPv4 | IPv6 |
| IPv6-first | `IPv6, IPv4` | IPv6 | IPv4 |

"First" must also be understood in the context of the relevant configuration layer:

- The `cluster-cidr` order controls Pod-network family ordering.
- The `service-cidr` order controls the default Service family.
- Node address preference can also be affected by the kubelet `node-ip` configuration.
- Longhorn ultimately depends on the address ordering observed on each node and Longhorn Pod, and on that ordering being consistent throughout the cluster.

Family ordering can affect:

- A Pod's `status.podIP` and `status.podIPs[0]`.
- The default family of a Service that does not explicitly select one.
- Applications or controllers that use only the primary Pod IP.
- Longhorn v1.12's existing endpoint and address-selection behavior.

### RKE2 IPv4-First Example

```yaml
# /etc/rancher/rke2/config.yaml
cluster-cidr: "10.42.0.0/16,fd42::/56"
service-cidr: "10.43.0.0/16,fd43::/112"
```

### RKE2 IPv6-First Example

```yaml
# /etc/rancher/rke2/config.yaml
cluster-cidr: "fd42::/56,10.42.0.0/16"
service-cidr: "fd43::/112,10.43.0.0/16"
```

RKE2 dual-stack must be configured when the cluster is created. An already-running IPv4-only cluster cannot be converted in place to dual-stack. The CNI, node network, routing, DNS, and firewall must also support both families.

Reference: [RKE2 Network Options — Dual-stack configuration](https://docs.rke2.io/networking/basic_network_options#dual-stack-configuration)

### A Service Can Have Its Own Family Policy

The cluster's primary family does not require every Service to use only that family. A Service can explicitly specify:

```yaml
spec:
  ipFamilyPolicy: RequireDualStack
  ipFamilies:
    - IPv6
    - IPv4
```

For a Service, `ipFamilies[0]` is the primary family. A secondary family can be added or removed later, but the primary family of an existing Service cannot be changed directly.

## 3. Relationship Between Longhorn and Dual-Stack

Longhorn includes both control-plane and data-plane components. When discussing dual-stack, it is important to identify which traffic path is involved.

| Scope | Examples | Relationship to IP family |
| --- | --- | --- |
| Control plane | Longhorn Manager, Kubernetes API, CSI controllers | Normally uses the Kubernetes cluster network and Service discovery |
| Backend data plane | V1/V2 engines, replicas, rebuild traffic, backup/restore callbacks | Engines and replicas must publish and connect to consistent, reachable endpoints |
| Backing-image traffic | Backing Image Manager (BIM), Backing Image Data Source (BIDS) | Download, synchronization, and send/receive endpoints must select the correct family |
| Storage Network | Additional backend network provided through Multus/NAD | When enabled, it carries Longhorn's in-cluster backend traffic |
| RWX frontend | Share Manager and NFS endpoint | This is a separate network boundary from the backend data-engine family |

### Longhorn Version History

| Version / ticket | Verified capability |
| --- | --- |
| v1.10 / [#2259](https://github.com/longhorn/longhorn/issues/2259) | The V1 Data Engine supports **single-stack IPv6**. The v1.10 release notes explicitly state that dual-stack and V2 IPv6 are not supported in that release. |
| v1.12 / [#11531](https://github.com/longhorn/longhorn/issues/11531) | The V1 and V2 Data Engines support dual-stack clusters when all nodes are uniformly IPv4-first or uniformly IPv6-first. Mixed ordering is not supported. |
| Target v1.13 / [#13050](https://github.com/longhorn/longhorn/issues/13050) | Work is in progress on an explicit backend data-plane family selector, allowing Longhorn to select only IPv4 or only IPv6 in a dual-stack cluster. |

Release notes:

- [Longhorn v1.10.0 release](https://github.com/longhorn/longhorn/releases/tag/v1.10.0)
- [Longhorn v1.12.0 release](https://github.com/longhorn/longhorn/releases/tag/v1.12.0)
- [Longhorn v1.12.1 release](https://github.com/longhorn/longhorn/releases/tag/v1.12.1)

## 4. Current Longhorn v1.12 Behavior

### Without a Storage Network

When all nodes use consistent family ordering, the following is a useful simplified model:

```text
IPv4-first dual-stack cluster
  Pod primary IP = IPv4
  Existing Longhorn address selection normally uses IPv4

IPv6-first dual-stack cluster
  Pod primary IP = IPv6
  Existing Longhorn address selection normally uses IPv6
```

Longhorn can therefore operate in a dual-stack cluster with consistent ordering, but it primarily **follows the primary family**. The user cannot independently choose the family used by the Longhorn data plane.

For example, every Longhorn Pod in an IPv4-first cluster may also have an IPv6 address, but v1.12 does not provide a supported global setting that guarantees that every engine, replica, V2/SPDK, BIM, and BIDS endpoint will use IPv6.

### With a Storage Network

A Storage Network is an additional network provided through Multus/NAD for Longhorn backend traffic. Longhorn v1.12 can use a Storage Network, but it does not provide a unified family selector. Existing implementations include primary-address selection and some IPv4-oriented assumptions or fallback behavior.

The following configuration therefore does not automatically mean that all Longhorn traffic will use IPv6:

```text
Cluster: IPv4-first dual-stack
Storage NAD: Provides both IPv4 and IPv6
Requirement: Force all Longhorn backend traffic to use IPv6
```

Until #13050 is completed and included in the Longhorn version being used, a dual-stack NAD alone cannot guarantee that all Longhorn data-plane components consistently select IPv6. The endpoints published by Instance Manager, engines, replicas, SPDK, BIM, and BIDS must be checked individually.

## 5. Main Ticket: Longhorn #13050

### Ticket Information

- Link: [#13050 — Support IPv4/IPv6 Dual-Stack](https://github.com/longhorn/longhorn/issues/13050)
- Type: Improvement
- Status: Open as of August 26, 2026
- Milestone: v1.13.0
- Priority: `priority/0`
- Created: May 6, 2026
- Last updated when verified: August 24, 2026

### Problem Addressed by the Ticket

The ticket explains that Longhorn has supported IPv4-only and IPv6-only clusters since v1.10 and has since added support for dual-stack family ordering. The next step is to allow the Longhorn backend data plane to explicitly enable IPv4 or IPv6 in a dual-stack cluster instead of only inheriting each Pod or CNI's primary ordering.

The practical requirements include:

- Use IPv6 consistently for Longhorn backend traffic in an IPv4-first cluster.
- Use IPv4 consistently for Longhorn backend traffic in an IPv6-first cluster.
- Prevent different Pod or node primary preferences from producing mixed Longhorn endpoint families.
- Give V1, V2/SPDK, BIM, and BIDS the same family contract.
- If the requested family is missing from a Storage Network, fail explicitly instead of silently using the other family or the cluster network.

### Proposed Design

The draft LEP and chart PR [#13826](https://github.com/longhorn/longhorn/pull/13826) propose a new global setting:

```yaml
defaultSettings:
  dataEngineIPFamily: ""
```

The corresponding Longhorn Setting name is:

```text
data-engine-ip-family
```

Proposed values and behavior:

| Value | Proposed behavior |
| --- | --- |
| `""` | Preserve legacy behavior. Follow existing primary/default address selection without guaranteeing a uniform endpoint family. |
| `ipv4` | Require IPv4 for the V1 and V2 data engines and backing-image backend traffic. |
| `ipv6` | Require IPv6 for the V1 and V2 data engines and backing-image backend traffic. |

Explicitly selecting `ipv4` or `ipv6` uses **strict, fail-closed** behavior:

- The selected family must exist and be usable.
- When a Storage Network is configured, its NAD is the authoritative network for backend traffic.
- If the Storage Network does not provide the selected family, Longhorn does not fall back to the other family.
- Longhorn also does not fall back to the Kubernetes cluster network.
- Affected components remain unsynchronized or unavailable until the network or setting is corrected.

Other important design details:

- The setting applies to both V1 and V2 Data Engines.
- It also applies to BIM and BIDS transfer endpoints.
- A V1 IPv4 listener uses `0.0.0.0:<port>`, while an IPv6 listener uses `[::]:<port>`.
- IPv6 host-and-port values must use a bracket-safe format such as `[fd42::15]:9500`.
- All volumes must be detached before changing the setting because Instance Manager, BIM, and BIDS Pods may need to be recreated.
- Existing backing-image CRs, UUIDs, metadata, and disk files should be preserved and reused. No data-copy migration is planned.
- The setting controls only the Longhorn backend data plane. It does not control the workload-facing NFS endpoint of an RWX volume.

> Important: This design comes from a draft LEP and pull request that are still under review. It is not a released v1.12.1 feature. Do not assume that `data-engine-ip-family` exists in v1.12.x.

### Related Implementation Pull Requests

As of August 26, 2026, the primary pull requests listed by the #13050 checklist had not all been merged:

| Component | Pull request | Purpose | Status when verified |
| --- | --- | --- | --- |
| Longhorn chart / LEP | [longhorn#13826](https://github.com/longhorn/longhorn/pull/13826) | Expose the `data-engine-ip-family` setting and document its design | Open, draft |
| Common network library | [go-common-libs#207](https://github.com/longhorn/go-common-libs/pull/207) | Add typed IP-family handling and family-aware Pod address resolution | Open |
| V2/SPDK engine | [longhorn-spdk-engine#655](https://github.com/longhorn/longhorn-spdk-engine/pull/655) | Select the family used by V2 listeners, callbacks, and endpoints | Open, draft |
| Instance Manager | [longhorn-instance-manager#1629](https://github.com/longhorn/longhorn-instance-manager/pull/1629) | Accept an optional data-engine IP family | Open, draft |
| Longhorn Manager | [longhorn-manager#5123](https://github.com/longhorn/longhorn-manager/pull/5123) | Configure and coordinate the Data Engine, BIM, and BIDS family | Open, draft |
| Backing Image Manager | [backing-image-manager#1007](https://github.com/longhorn/backing-image-manager/pull/1007) | Use a configurable family for backing-image traffic | Open, draft |

## 6. Related Longhorn Tickets

### #2259: IPv6 for the V1 Data Engine

- Link: [#2259 — IPv6 for V1 Data Engine](https://github.com/longhorn/longhorn/issues/2259)
- Status: Closed / completed
- Milestone: v1.10.0
- Scope: Resolve V1 volume attachment and iSCSI/data-engine issues in single-stack IPv6 clusters.
- This does not mean that v1.10 supports dual-stack. The v1.10 release notes explicitly exclude dual-stack.

### #11531: Dual-Stack with Consistent Ordering

- Link: [#11531 — Support IPv4/IPv6 Dual-Stack with IPv6 Family First or IPv4 Family First](https://github.com/longhorn/longhorn/issues/11531)
- Status: Closed / completed
- Milestone: v1.12.0
- Scope: Allow the Longhorn V1 and V2 Data Engines to operate when all nodes in a dual-stack cluster are IPv4-first, or when all nodes are IPv6-first.
- Limitation: Mixed family ordering across nodes in the same cluster is unsupported and may cause connectivity failures between engines and replicas.

### #13050: Explicit Family Selection in Dual-Stack

- Link: [#13050 — Support IPv4/IPv6 Dual-Stack](https://github.com/longhorn/longhorn/issues/13050)
- Status: Open
- Milestone: v1.13.0
- Scope: Add consistent and explicit backend data-plane IP-family selection, addressing the limitation that #11531 only supports following a consistent primary ordering.

The relationship between these tickets can be summarized as follows:

```text
#2259 / v1.10
  V1 supports IPv6-only clusters
        |
        v
#11531 / v1.12
  V1 and V2 support dual-stack with consistent family ordering
        |
        v
#13050 / target v1.13
  Select IPv4 or IPv6 explicitly for the Longhorn backend in dual-stack
```

## 7. Common Scenarios

| Scenario | Longhorn v1.12.x | After the proposed #13050 work |
| --- | --- | --- |
| IPv4-first without a Storage Network | Longhorn normally follows primary IPv4 | Select either `ipv4` or `ipv6` |
| IPv6-first without a Storage Network | Longhorn normally follows primary IPv6 | Select either `ipv4` or `ipv6` |
| IPv4-first with a dual-stack Storage NAD; all backend traffic should use IPv6 | No supported global selector; a uniform IPv6 result cannot be guaranteed | Set `data-engine-ip-family=ipv6`; the NAD must provide usable IPv6 |
| IPv6-first with an IPv4-only Storage NAD; backend traffic should use IPv4 | Behavior must be validated per version and component because no unified selector contract exists | Set `data-engine-ip-family=ipv4` |
| IPv6 is explicitly selected, but the Storage NAD provides only IPv4 | The strict #13050 contract does not exist | Fail closed without using IPv4 or the cluster network |
| The workload-facing NFS endpoint of an RWX volume should use another family | Do not treat it as the same network boundary as engine/replica backend traffic | It remains controlled by the Service or `endpoint-network-for-rwx-volume` |

## 8. Verification Commands

Check node address ordering:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{" "}{end}{"\n"}{end}'
```

Check the primary and all addresses of Longhorn Pods:

```bash
kubectl -n longhorn-system get pods \
  -o custom-columns='NAME:.metadata.name,PRIMARY:.status.podIP,ALL:.status.podIPs[*].ip'
```

Check Service family policies:

```bash
kubectl -n longhorn-system get services \
  -o custom-columns='NAME:.metadata.name,POLICY:.spec.ipFamilyPolicy,FAMILIES:.spec.ipFamilies,IPS:.spec.clusterIPs'
```

When a Multus Storage Network is configured, also inspect the `k8s.v1.cni.cncf.io/network-status` annotation on Longhorn Pods. The default Pod IP alone is not sufficient.

## 9. Final Conclusion

The precise conclusion of the shared discussion is:

1. Longhorn v1.12 supports dual-stack with consistent family ordering. It is inaccurate to say that its data plane has no dual-stack support at all.
2. In released v1.12.x versions, Longhorn normally follows the primary Pod/network family: IPv4-first normally selects IPv4, while IPv6-first normally selects IPv6.
3. What is missing is a global family selector shared by V1, V2, BIM, and BIDS. In particular, when a Storage Network is configured, v1.12.x cannot guarantee that all backend traffic will use a user-selected secondary family.
4. Issue #13050 proposes `data-engine-ip-family`, but as of August 26, 2026, it remains an in-development feature targeting v1.13.0.
