Here is the updated Markdown **with the embedded spec reference** included:

---

# CSI Detach Sequence — ControllerUnpublish Before NodeUnstage

## ✅ Expected CSI Detach Order (Normal Case)

In a **clean and graceful detach**, the sequence defined by the Container Storage Interface (CSI) specification is:

1. **NodeUnpublishVolume** — unmounts the volume from the pod’s target path.
2. **NodeUnstageVolume** — unmounts and cleans up the node’s staging path.
3. **ControllerUnpublishVolume** — detaches the volume from the node at the controller level.

> In other words:
> **NodeUnpublish → NodeUnstage → ControllerUnpublish**

From the CSI spec discussion:

> “`ControllerUnpublishVolume()` **MUST** be called after all `NodeUnstageVolume` and `NodeUnpublishVolume` on the volume are called and succeed.” ([GitHub][1])

---

## ⚠️ Why the Logs Appear “Out of Order”

In your log output:

* **ControllerUnpublishVolume** at `16:35`
* **NodeUnpublishVolume / NodeUnstageVolume** at `16:47`

This reversal of the “normal” order can occur in **non-graceful or force-detach** scenarios within Kubernetes.

### Common Causes

1. **Force Detach Timeout / Unhealthy Node**

   * If a node becomes `NotReady`, `Unreachable`, or otherwise unhealthy, Kubernetes may delete the VolumeAttachment object prematurely, triggering **ControllerUnpublishVolume** before kubelet finishes `NodeUnpublish` / `NodeUnstage`.
   * As documented:

     > “In any situation where a pod deletion has not succeeded for 6 minutes, Kubernetes will force detach volumes being unmounted if the node is unhealthy at that instant. … Any workload still running on the node that uses a force-detached volume will cause a violation of the CSI specification, which states that `ControllerUnpublishVolume` ‘must be called after all `NodeUnstageVolume` and `NodeUnpublishVolume` on the volume are called and succeed’.” ([Kubernetes][2])

2. **Out-of-Service Node Workflow**

   * When a node is marked `out-of-service`, pods are force-deleted and volume detach operations happen immediately, leading to **ControllerUnpublishVolume** being called ahead of node-side cleanup. ([Kubernetes][3])

---

## 🧭 How to Verify What Happened

You can check which path was taken:

1. **VolumeAttachment Events**

   * Inspect if the VolumeAttachment for the volume was deleted around 16:35. That indicates the external-attacher triggered it early.

2. **Node Conditions / Taints**

   * Check the node status around 16:30-16:40 for `NotReady`, `Unreachable`, or a taint `node.kubernetes.io/out-of-service`.

3. **Kube Controller Manager Config**

   * Check if `--disable-force-detach-on-timeout=false` (the default) is in use. If force detach is enabled it allows the detach sequence to skip node-side cleanup after a timeout. ([Kubernetes][2])

4. **Logs of External Attacher / CSI Controller**

   * Look for entries matching `ControllerUnpublishVolume` at the earlier timestamp.

---

## 🧩 Summary

| Situation           | Order Seen                                        | Explanation                                                 | Risk                                               |
| ------------------- | ------------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------- |
| Normal (graceful)   | NodeUnpublish → NodeUnstage → ControllerUnpublish | Standard CSI workflow                                       | ✅ Safe                                             |
| Force Detach        | ControllerUnpublish → NodeUnpublish → NodeUnstage | Node timeout or unhealthy, Kubernetes cleanup fallback path | ⚠️ Possible residual mounts or data integrity risk |
| Out-of-Service Node | ControllerUnpublish first                         | Node tainted out-of-service → immediate detach              | ⚠️ Same risk as above                              |

---

## 🛠️ Recommendations

* **If strict CSI ordering is required** (especially for encrypted volumes or workloads with high data integrity needs):

  * Consider disabling force detach on timeout in `kube-controller-manager` (`--disable-force-detach-on-timeout=true`).
  * Be aware this may slow recovery when nodes hang. ([Kubernetes][2])

* **If using block-mode volumes or VM workloads** (e.g., via KubeVirt) on top of Longhorn/CSI:

  * Ensure your storage layer handles stale attachments and loop devices properly when the normal detach sequence is changed.

---

In short:
Yes — seeing `ControllerUnpublishVolume` before `NodeUnstageVolume` is *not* normal for the graceful detach path,
but this ordering **is expected and documented** behavior when Kubernetes runs a **force detach** or **out-of-service node** recovery path (see spec/reference above).

[1]: https://github.com/container-storage-interface/spec/issues/473?utm_source=chatgpt.com "ControllerUnpublishVolume from all nodes - confusing spec"
[2]: https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/?utm_source=chatgpt.com "Node Shutdowns - Kubernetes"
[3]: https://kubernetes.io/blog/2023/08/16/kubernetes-1-28-non-graceful-node-shutdown-ga/?utm_source=chatgpt.com "Kubernetes 1.28: Non-Graceful Node Shutdown Moves to GA"
