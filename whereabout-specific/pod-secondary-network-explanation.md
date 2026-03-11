# Pod Secondary Network Explanation: Whereabouts IPAM vs Static IPAM

## Short Answer

These Pods can communicate even though they use different `NetworkAttachmentDefinition` (NAD) objects, because their secondary interfaces still end up on the same effective network:

- same bridge: `mgmt-br`
- same VLAN: `2011`
- same subnet: `172.16.0.0/24`

The NAD name itself does not determine reachability. What matters is where the interface is attached and what subnet it uses.

## Core Idea

Different NADs do not automatically mean isolation.

If two NADs both attach Pod interfaces to:

- the same bridge
- the same VLAN
- the same subnet

then those Pods can usually communicate directly at Layer 2.

A useful mental model:

- `NAD` = how the interface is created and attached
- `bridge + VLAN + subnet` = what determines whether the interfaces are on the same network

## Why These Pods Can Ping Each Other

In your case, one Pod received an address like `172.16.0.17/24` from a Whereabouts-based NAD, and another Pod used a static NAD with `172.16.0.10/24`.

They can still reach each other because:

1. both secondary interfaces are attached to `mgmt-br`
2. both use VLAN `2011`
3. both addresses are in `172.16.0.0/24`
4. nothing is blocking traffic between them

Because `172.16.0.10` is in the directly connected subnet, the kernel sends traffic out the secondary interface, uses ARP to resolve the peer MAC address, and then sends packets directly over Layer 2.

## Packet Flow Inside the Pod

From the Pod:

```text
ip addr show dev lhnet1

3: lhnet1@if88103: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 56:38:73:2a:66:0f brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.16.0.17/24 brd 172.16.0.255 scope global lhnet1
```

```text
ip route

default via 169.254.1.1 dev eth0
169.254.1.1 dev eth0 scope link
172.16.0.0/24 dev lhnet1 proto kernel scope link src 172.16.0.17
```

```text
ip neigh show dev lhnet1

172.16.0.10 lladdr 0e:63:d3:37:43:ed REACHABLE
```

```text
ping 172.16.0.10

64 bytes from 172.16.0.10: icmp_seq=1 ttl=64 time=0.168 ms
64 bytes from 172.16.0.10: icmp_seq=2 ttl=64 time=0.137 ms
```

This tells us:

- `172.16.0.10` is treated as directly connected through `lhnet1`
- the Pod does not use the default route on `eth0`
- the Pod sends ARP on `lhnet1`
- the peer replies with its MAC address
- ICMP then goes directly across the same Layer 2 segment

## Routing Decision

The key route is:

```text
172.16.0.0/24 dev lhnet1 proto kernel scope link src 172.16.0.17
```

This means any destination in `172.16.0.0/24` is sent directly through `lhnet1`.

So when the Pod sends traffic to `172.16.0.10`, it does not use:

```text
default via 169.254.1.1 dev eth0
```

The subnet route wins because it is more specific than the default route.

## Same-Node View

If both Pods are on the same node and both secondary interfaces land on `mgmt-br` with VLAN `2011`, then they share the same local Layer 2 segment.

```text
+----------------------------------------------------------------------------------+
| Node: hp-155-tink-system                                                         |
|                                                                                  |
|  Linux bridge: mgmt-br                                                           |
|  VLAN: 2011                                                                      |
|                                                                                  |
|        +---------------------------+          +---------------------------+       |
|        | Pod A                     |          | Pod B                     |       |
|        | (Whereabouts NAD)         |          | (Static NAD)              |       |
|        |                           |          |                           |       |
|        |  eth0: cluster network    |          |  eth0: cluster network    |       |
|        |  default via 169.254.1.1  |          |  default via 169.254.1.1  |       |
|        |                           |          |                           |       |
|        |  lhnet1: 172.16.0.17/24   |          |  net1: 172.16.0.10/24     |       |
|        |  route: 172.16.0.0/24     |          |  route: 172.16.0.0/24     |       |
|        +------------+--------------+          +-------------+-------------+       |
|                     |                                         |                     |
|                     | veth / pod interface                    | veth / pod interface |
|                     |                                         |                     |
|                     +-------------------+   +-----------------+                     |
|                                         |   |                                       |
|                                      +--v---v------------------+                    |
|                                      |      mgmt-br            |                    |
|                                      |   same L2 segment       |                    |
|                                      +-----------+-------------+                    |
|                                                  |                                  |
|                                                  | VLAN 2011                        |
|                                                  |                                  |
+--------------------------------------------------+----------------------------------+
                                                   |
                                                   v

                     Pod A (172.16.0.17) -> ARP -> Pod B (172.16.0.10)
```

Flow:

1. Pod A checks its routing table.
2. `172.16.0.10` matches `172.16.0.0/24`.
3. Pod A sends ARP on `lhnet1`.
4. Pod B replies with its MAC address.
5. ICMP echo request and reply move directly over Layer 2.

## Cross-Node View

The same logic can apply when the Pods are on different nodes, but there is one extra requirement: the underlying node network must really provide the same Layer 2 path between those nodes.

It is not enough that both NAD YAMLs happen to use:

- the same bridge name
- the same VLAN number

Those settings must map to a real cross-node reachable network.

Pods on different nodes can usually communicate directly only if:

1. the two NADs ultimately attach to the same type of secondary network
2. each node bridge or uplink is actually connected to VLAN `2011`
3. the Pod secondary IPs are in the same subnet
4. no firewall, ACL, network policy, or switch configuration blocks the traffic

```text
Node A                                   Node B
+--------------------+                  +--------------------+
| Pod A              |                  | Pod B              |
| net1 172.16.0.17   |                  | net1 172.16.0.10   |
+---------+----------+                  +---------+----------+
          |                                       |
       mgmt-br                                 mgmt-br
          |                                       |
          +----------- VLAN 2011 L2 -------------+
                      same subnet 172.16.0.0/24
```

If that Layer 2 path really exists, then the Pods can usually:

- ARP for each other
- exchange ICMP, TCP, and UDP directly
- communicate without a Layer 3 router

## Important Cross-Node Limitation

Having the same bridge name on both nodes does not guarantee connectivity.

For example:

- Node A may have `mgmt-br` correctly attached to VLAN `2011`
- Node B may also have `mgmt-br`, but its uplink may not actually carry VLAN `2011`

In that case, the Pod IPs can still look correct, but the Pods will fail to communicate because the underlying Layer 2 network is not truly shared end to end.

The more precise statement is:

Pods on different nodes can communicate only when their secondary interfaces ultimately land on the same cross-node reachable Layer 2 segment, the same VLAN, and the same subnet.

## Configuration Examples

### Static NAD

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: storagenetwork-static
  namespace: harvester-system
spec:
  config: '{
    "cniVersion":"0.3.1",
    "type":"bridge",
    "bridge":"mgmt-br",
    "promiscMode":true,
    "vlan":2011,
    "ipam":{
      "type":"static"
    }
  }'
```

### Pod Using Static IP Assignment

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: database-server
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [{
        "name": "storagenetwork-static",
        "namespace": "harvester-system",
        "ips": ["172.16.0.10/24"]
      }]
spec:
  containers:
  - name: postgres
    image: postgres:15-alpine
    env:
    - name: POSTGRES_PASSWORD
      value: changeme
```

### Whereabouts NAD

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  annotations:
    storage-network.settings.harvesterhci.io: "true"
  name: storagenetwork-frqx7
  namespace: harvester-system
spec:
  config: '{
    "cniVersion":"0.3.1",
    "type":"bridge",
    "bridge":"mgmt-br",
    "promiscMode":true,
    "vlan":2011,
    "ipam":{
      "type":"whereabouts",
      "range":"172.16.0.0/24",
      "exclude":["172.16.0.1/28"]
    }
  }'
```

## Why the Static Pod and Whereabouts Pod Still Communicate

Even though the Pods use different NADs, both NADs ultimately place the secondary interface into:

- `mgmt-br`
- VLAN `2011`
- subnet `172.16.0.0/24`

That is enough for direct Layer 2 communication. If the Pods are on different nodes, the node network must also provide the same Layer 2 connectivity across those nodes.

## Practical Verification

Check Pod placement:

```bash
kubectl get pod -o wide
```

Check the secondary interface, routing, neighbor resolution, and connectivity:

```bash
kubectl exec -it <pod-a> -- ip addr show dev net1
kubectl exec -it <pod-a> -- ip route
kubectl exec -it <pod-a> -- ip neigh show dev net1
kubectl exec -it <pod-a> -- ping 172.16.0.10
```

If cross-node communication fails, inspect the node network too:

```bash
ip link show mgmt-br
bridge vlan show
ip link
```

## Conclusion

These Pods are reachable to each other not because they use the same NAD, but because their secondary interfaces end up on the same bridge, the same VLAN, and the same subnet. For Pods on different nodes, the underlying node network must also provide the same cross-node Layer 2 connectivity.
