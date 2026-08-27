# Dual-Stack, IP Family Ordering, and Longhorn

## Summary

- **Dual-stack** means that a cluster enables IPv4 and IPv6 at the same time. A typical dual-stack Pod receives one IPv4 address and one IPv6 address.
- **IPv4-first** and **IPv6-first** describe address-family ordering and the primary/default family. They do not mean that the other family is unavailable.
- RKE2 uses the CIDR order in `cluster-cidr` and `service-cidr` to define the cluster's primary family. Dual-stack must be configured when the cluster is created.
- Longhorn v1.12 supports IPv4-first and IPv6-first dual-stack clusters, provided that all nodes use the same family ordering.
- Longhorn v1.12 does not provide a global setting that explicitly forces all backend data-plane traffic to use IPv4 or IPv6. Existing behavior generally follows the primary Pod/network family or legacy address-selection logic.
- [Longhorn issue #13050](https://github.com/longhorn/longhorn/issues/13050) is adding `preferred-data-engine-ip-family`, which will allow the Longhorn backend data plane and manager-directed backing-image traffic to explicitly select `ipv4` or `ipv6`. As of the verification date, this work is still in progress and targets the v1.13.0 milestone.

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
  preferredDataEngineIPFamily: default
```

The corresponding Longhorn Setting name is:

```text
preferred-data-engine-ip-family
```

Proposed values and behavior:

| Value | Proposed behavior |
| --- | --- |
| `default` | Preserve legacy data-engine address selection. Backing-image operations use the automatic storage-first resolver. |
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
- All volumes must be detached before changing the setting. Capable V2 Instance Manager Pods remain running while applied-family status converges; BIM is restarted only through its safe restart path, and a mismatched active BIDS blocks the transition rather than being deleted as a workaround.
- Existing backing-image CRs, UUIDs, metadata, and disk files should be preserved and reused. No data-copy migration is planned.
- The setting controls only the Longhorn backend data plane. It does not control the workload-facing NFS endpoint of an RWX volume.

> Important: This design comes from a draft LEP and pull request that are still under review. It is not a released v1.12.1 feature. Do not assume that `preferred-data-engine-ip-family` exists in v1.12.x.

### Related Implementation Pull Requests

As of August 26, 2026, the primary pull requests listed by the #13050 checklist had not all been merged:

| Component | Pull request | Purpose | Status when verified |
| --- | --- | --- | --- |
| Longhorn chart / LEP | [longhorn#13826](https://github.com/longhorn/longhorn/pull/13826) | Expose the `preferred-data-engine-ip-family` setting and document its design | Open, draft |
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
| IPv4-first with a dual-stack Storage NAD; all backend traffic should use IPv6 | No supported global selector; a uniform IPv6 result cannot be guaranteed | Set `preferred-data-engine-ip-family=ipv6`; the NAD must provide usable IPv6 |
| IPv6-first with an IPv4-only Storage NAD; backend traffic should use IPv4 | Behavior must be validated per version and component because no unified selector contract exists | Set `preferred-data-engine-ip-family=ipv4` |
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

## 9. LEP Review: Longhorn Service IP-Family Policy and Harvester

The draft LEP adds Kubernetes Service behavior alongside the backend data-engine family setting. These are separate features and must not be treated as one global Longhorn networking switch.

### Four Independent Network Decisions

| Configuration | Owner | What it selects |
| --- | --- | --- |
| Harvester `storage-network` | Harvester controller and Longhorn Storage Network setting | The Multus/NAD addresses available for Longhorn backend traffic |
| Longhorn `preferred-data-engine-ip-family` | Longhorn Manager | The family used by supported engine, replica, callback, and manager-directed backing-image traffic |
| Harvester `rwx-network` / Longhorn `endpoint-network-for-rwx-volume` | Harvester and Longhorn | The workload-facing network used by the Share Manager NFS export |
| Longhorn `service.ipFamilyPolicy` | Longhorn chart | The Kubernetes Service VIP family policy for chart-rendered Longhorn Services |

Changing a Service policy does not select Pod addresses, engine or replica listener addresses, the Storage Network family, or the RWX endpoint network.

### Interaction Between `preferred-data-engine-ip-family` and `storage-network`

The draft LEP defines an authoritative-network rule for explicit family selection:

- When Longhorn's `storage-network` setting is empty, an explicit family uses the matching address from the cluster-network Pod addresses.
- When `storage-network` is configured, that Multus/NAD network is authoritative. The requested family must be present in the Pod's Multus `network-status` for the storage interface.
- Longhorn does not fall back to the opposite family or move backend traffic to the cluster network when the configured Storage Network lacks the requested family.

Assuming that `preferred-data-engine-ip-family=ipv6` has passed the all-volumes-detached gate and has been successfully applied, the selection is:

```text
Is Longhorn storage-network configured?
|
+-- No
|   +-- Pod has usable cluster-network IPv6
|   |   +-- Use that IPv6 address
|   +-- Pod lacks usable cluster-network IPv6
|       +-- Fail
|
+-- Yes
    +-- Storage NAD assigns usable IPv6 and network-status reports it
    |   +-- Use the storage-network IPv6 address
    +-- Storage NAD lacks usable IPv6
        +-- Fail; no IPv4 or cluster-network fallback
```

For an IPv4-primary dual-stack cluster, the resulting matrix is:

| Storage Network | `preferred-data-engine-ip-family=ipv6` result |
| --- | --- |
| Not configured | Use the secondary IPv6 Pod address from the cluster network; fail if unavailable |
| IPv4-only NAD | Fail closed; do not use the NAD's IPv4 address or the cluster network's IPv6 address |
| IPv6-only NAD | Supported by the Longhorn design if every relevant Pod receives a usable, routable IPv6 address |
| Dual-stack NAD | Select the NAD's IPv6 address; IPv4 remains available but is not selected |

The inverse is also true: `preferred-data-engine-ip-family=ipv4` fails with an IPv6-only authoritative Storage Network. A dual-stack Storage Network can satisfy either explicit setting.

The LEP gives the IPv6-on-IPv4-only mismatch as a normative example. The desired value remains `ipv6`, Instance Manager reports unsynchronized, affected endpoints are cleared or withheld, and V1, V2, BIM, and BIDS operations cannot converge until IPv6 becomes available or the setting changes. The usable backend family is **none**, not IPv4.

This strict behavior applies to explicit `ipv4` and `ipv6`. The `default` value is different:

- Data-engine requests retain legacy primary-address selection.
- Backing-image operations omit the family and use the automatic resolver.
- If `lhnet1` exists, the automatic resolver chooses its first usable global-unicast address in interface/CNI order.
- If `lhnet1` is present but unusable, automatic backing-image resolution fails rather than falling back to `POD_IP`.
- Only when `lhnet1` is absent does the automatic backing-image resolver validate and use the primary `POD_IP`.

The configured network must actually assign the requested family to every relevant Pod or interface. For IPv6, ULA/global-unicast addresses are acceptable, but link-local addresses are not usable endpoint candidates. Routing and firewall connectivity between Longhorn nodes remain external prerequisites; the LEP does not configure the CNI, NAD, Whereabouts, routing, or firewall.

#### Harvester Qualification

At the Longhorn level, an IPv6-only Whereabouts-backed NAD can satisfy an explicit `ipv6` request. Harvester's current managed `storage-network` API, however, accepts only an IPv4 CIDR. The proposed Harvester IPv4-first dual-stack design adds an optional secondary IPv6 range and expects an IPv4-first pair such as:

```text
10.52.0.0/24,fd52::/120
```

The expected Harvester integration is therefore a dual-stack Storage Network combined with explicit Longhorn selection:

```text
Harvester storage-network: IPv4 + IPv6
Longhorn preferred-data-engine-ip-family: ipv6
Selected backend address: IPv6 on lhnet1
```

An IPv6-only NAD may be valid to Longhorn directly, but it is not currently a supported configuration through Harvester's managed Storage Network setting. Harvester integration tests should verify the generated Whereabouts `ipRanges`, Multus `network-status`, and strict Longhorn selection on every relevant Pod.

References:

- [LEP: Storage Network Interaction](https://github.com/COLDTURNIP/longhorn/blob/12763101438af1888554956d4f3fc2197212a9d8/enhancements/20260824-data-engine-ip-family.md#storage-network-interaction)
- [LEP: Storage-network mismatch test plan](https://github.com/COLDTURNIP/longhorn/blob/12763101438af1888554956d4f3fc2197212a9d8/enhancements/20260824-data-engine-ip-family.md#storage-network-mismatch)
- [Harvester IPv4-first dual-stack HEP: workload networks](https://github.com/harvester/harvester/blob/master/enhancements/20260528-dual-stack-ipv4-first.md#story-8--administrator-configures-storage-rwx-and-vm-migration-networks-with-dual-stack-cidrs-experimental)

### Static Services Rendered by the Longhorn Chart

For standalone Longhorn, the proposed chart value is:

```yaml
service:
  ipFamilyPolicy: PreferDualStack
```

Because Harvester installs Longhorn as a subchart, the equivalent Harvester umbrella value is:

```yaml
longhorn:
  service:
    ipFamilyPolicy: PreferDualStack
```

The value applies only to these chart-rendered Longhorn Services:

- `longhorn-backend`
- `longhorn-frontend`
- Admission webhook
- Recovery backend
- The conditional OpenShift `longhorn-ui` Service

With `PreferDualStack`, Kubernetes allocates both IPv4 and IPv6 ClusterIPs when the cluster has dual-stack Service CIDRs. On a single-stack cluster, it safely falls back to one family. If `ipFamilies` is not specified separately, Kubernetes determines the primary family and ordering from the cluster's Service CIDR ordering. In an IPv4-first Harvester cluster, IPv4 therefore remains the primary Service address.

Reference: [Kubernetes dual-stack Services](https://kubernetes.io/docs/concepts/services-networking/dual-stack/#services)

### Dynamic RWX Share Manager Services

An RWX Longhorn volume is exported by a Share Manager Pod running an NFS server. The Longhorn Share Manager controller, rather than Helm, creates the Service that exposes this server:

```text
Workload Pod -> Share Manager Service -> Share Manager NFS Pod -> Longhorn volume
```

The Helm `service.ipFamilyPolicy` value does not affect this dynamically created Service. Longhorn Manager must set and reconcile its policy separately.

The Service has two possible forms:

| RWX configuration | Service form |
| --- | --- |
| `endpoint-network-for-rwx-volume` is empty | Selector-based ClusterIP Service |
| A dedicated RWX endpoint network is configured | Headless Service with manually managed endpoints |

In released Longhorn v1.12.1, `createServiceManifest` does not set `spec.ipFamilyPolicy`, and the controller does not reconcile this field on an existing Service. For the normal selector-based Service, Kubernetes consequently defaults the policy to `SingleStack`.

There is one Kubernetes nuance: a headless Service **without a selector** defaults differently; current Kubernetes documentation states that an omitted policy defaults to `RequireDualStack`. Therefore, the statement "Longhorn omits `ipFamilyPolicy`, so every RWX Service is `SingleStack`" is accurate for the normal selector-based RWX Service but is too broad for the dedicated-network headless form.

References:

- [Longhorn v1.12.1 Share Manager Service construction](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/controller/share_manager_controller.go#L1305-L1340)
- [Kubernetes headless Service behavior](https://kubernetes.io/docs/concepts/services-networking/dual-stack/#headless-services-without-selector)

### Current Behavior Versus the Draft LEP

The linked LEP proposes that Longhorn Manager will:

- Set `spec.ipFamilyPolicy: PreferDualStack` on both selector-based and headless Share Manager Services.
- Reconcile existing Share Manager Services in place.
- Preserve the Service UID and the existing primary ClusterIP.
- Allow Kubernetes to fall back to one family on a single-stack cluster.
- Keep the generic `DataStore.CreateService` path policy-neutral so SystemRollout and system-backup restore behavior is not changed globally.

This is a **proposed controller behavior**, not behavior present in Longhorn v1.12.1. The linked [chart/LEP PR #13826](https://github.com/longhorn/longhorn/pull/13826) changes chart-rendered resources and documents the desired controller contract; the corresponding Longhorn Manager implementation is required for dynamic Share Manager Services.

Reference: [Draft Dual-Stack Data Engine IP Family LEP](https://github.com/COLDTURNIP/longhorn/blob/12763101438af1888554956d4f3fc2197212a9d8/enhancements/20260824-data-engine-ip-family.md)

### Assessment of the Review Comment

The review comment is correct in identifying the principal gap: workload-facing RWX exports are represented by controller-created Kubernetes Services, and the normal selector-based Service remains single-stack when Longhorn leaves `ipFamilyPolicy` unspecified.

A more precise version is:

> For RWX volumes, Longhorn's Share Manager controller creates the Kubernetes Service that exposes the NFS server. Current Longhorn code does not specify `spec.ipFamilyPolicy`, so the normal selector-based Service defaults to `SingleStack`. The Helm `service.ipFamilyPolicy` value affects only chart-rendered Longhorn control-plane Services; it does not cover dynamically created Share Manager Services. Longhorn Manager must therefore separately create and reconcile Share Manager Services with `PreferDualStack`. The dedicated-network headless form should also be made explicit so its behavior does not depend on Kubernetes defaulting.

### Harvester Adoption Checklist

1. When Harvester adopts the implementing Longhorn chart, explicitly set `longhorn.service.ipFamilyPolicy: PreferDualStack` if the Harvester chart intends all Longhorn static Services to prefer dual-stack. The upstream default is empty and preserves `SingleStack` behavior.
2. Confirm that the bundled Longhorn Manager contains the separate Share Manager reconciliation change; the Helm value alone does not fix RWX Services.
3. Test both selector-based and dedicated-network headless RWX Services on IPv4-only and IPv4-first dual-stack clusters.
4. For an existing RWX Service, verify that reconciliation adds the secondary family without changing its UID or primary ClusterIP, and run NFS read/write I/O before and after reconciliation.
5. Verify that `preferred-data-engine-ip-family`, `storage-network`, `endpoint-network-for-rwx-volume`, and Service IP-family policy remain independent in integration tests.

## 10. Final Conclusion

The precise conclusion of the shared discussion is:

1. Longhorn v1.12 supports dual-stack with consistent family ordering. It is inaccurate to say that its data plane has no dual-stack support at all.
2. In released v1.12.x versions, Longhorn normally follows the primary Pod/network family: IPv4-first normally selects IPv4, while IPv6-first normally selects IPv6.
3. What is missing is a global family selector shared by V1, V2, BIM, and BIDS. In particular, when a Storage Network is configured, v1.12.x cannot guarantee that all backend traffic will use a user-selected secondary family.
4. Issue #13050 proposes `preferred-data-engine-ip-family`, but as of August 27, 2026, it remains an in-development feature targeting v1.13.0.
5. The proposed Helm `service.ipFamilyPolicy` value covers only static chart-rendered Longhorn Services. Dynamic RWX Share Manager Services require a separate Longhorn Manager implementation.
6. For current Longhorn, the normal selector-based RWX Service defaults to `SingleStack`; the draft LEP proposes explicit `PreferDualStack` reconciliation for both selector-based and headless Share Manager Services.
7. For explicit family selection, a configured Storage Network is authoritative. The requested family must exist on that NAD; otherwise Longhorn fails closed without using the opposite family or falling back to the cluster network.
