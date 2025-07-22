# Kubernetes CSI Detach/Unstage Race Condition Discussion

## Table of Contents
- [Overview](#overview)
- [Key Concepts](#key-concepts)
- [Normal Volume Detach Flow](#normal-volume-detach-flow)
- [Race Condition Details](#race-condition-details)
- [Source Code References](#source-code-references)
- [CSI Call Paths](#csi-call-paths)
  - [ControllerUnpublishVolume](#controllerunpublishvolume-call-path)
  - [NodeUnstageVolume (Block Mode PVC)](#nodeunstagevolume-block-mode-pvc-call-path)
  - [NodeUnpublishVolume](#nodeunpublishvolume-call-path)
- [Summary Tables](#summary-tables)

---

## Overview
This document analyzes a race condition in Kubernetes involving the attach/detach controller, kubelet, and CSI drivers (e.g., Longhorn). The issue occurs when the CSI `NodeUnstageVolume` call is missing entirely, rather than simply being invoked after `ControllerUnpublishVolume`. This can cause problems for CSI driver implementations, as the expected cleanup and resource release steps are skipped.

---

## Key Concepts
- **Attach/Detach Controller**: Manages Desired State of World (DSW) and Actual State of World (ASW) for volume attachments in the control plane.
- **Kubelet**: Runs on each node, responsible for mounting/unmounting and staging/unstaging volumes.
- **CSI Driver**: Implements the Container Storage Interface, handling gRPC calls such as `NodeUnpublishVolume`, `NodeUnstageVolume`, and `ControllerUnpublishVolume`.

---

## Normal Volume Detach Flow
1. **Pod Deletion**: Kubelet detects the pod removal and initiates volume unmount.
2. **Unmount and Unstage**: Kubelet calls `NodeUnpublishVolume` (unmount from pod) followed by `NodeUnstageVolume` (unstage from staging path).
3. **ASW Update**: Kubelet updates ASW to indicate the volume is no longer mounted.
4. **Controller Detach**: The attach/detach controller observes the volume is not mounted and calls `DetachVolume`, triggering `ControllerUnpublishVolume`.

---

## Race Condition Details
- If a pod is deleted rapidly, kubelet may update ASW before calling `NodeUnstageVolume`.
- The attach/detach controller, seeing `MountedByNode == false`, may call `DetachVolume` (and thus `ControllerUnpublishVolume`) before the node completes unstaging.
- In some cases, the device-level unmount (`NodeUnstageVolume`) is **never called at all**. This means the CSI driver never receives the expected cleanup call, potentially leading to resource leaks or inconsistent state.

### Detailed Flow
This section documents the code flow in Kubernetes that leads to the CSI Detach/Unstage race, focusing on why `NodeUnstageVolume` (CSI UnmountDevice) may be **missing entirely** before or after `ControllerUnpublishVolume` (CSI Detach).

#### 1. Reconciler Loop Entry Point
- **File:** pkg/kubelet/volumemanager/reconciler/reconciler.go
- **Function:** `reconciler.Run()` ([L30](https://github.com/kubernetes/kubernetes/blob/a78aa47129b8539636eb86a9d00e31b2720fe06b/pkg/kubelet/volumemanager/reconciler/reconciler.go#L30))
- Starts the main reconciliation loop, repeatedly calling `rc.reconcile()`.

#### 2. Main Reconcile Logic
- **File:** pkg/kubelet/volumemanager/reconciler/reconciler.go
- **Function:** `reconciler.reconcile()` ([L37](https://github.com/kubernetes/kubernetes/blob/a78aa47129b8539636eb86a9d00e31b2720fe06b/pkg/kubelet/volumemanager/reconciler/reconciler.go#L37))
- Key steps:
  1. If `readyToUnmount` is true, calls `rc.unmountVolumes()`.
  2. Calls `rc.mountOrAttachVolumes()`.
  3. If `readyToUnmount` is true, calls `rc.unmountDetachDevices()` and `rc.cleanOrphanVolumes()`.

#### 3. Pod Deletion: UnmountVolume (NodeUnpublish)
- **File:** pkg/kubelet/volumemanager/reconciler/reconciler_common.go
- **Function:** `unmountVolumes()` ([L147](https://github.com/kubernetes/kubernetes/blob/a78aa47129b8539636eb86a9d00e31b2720fe06b/pkg/kubelet/volumemanager/reconciler/reconciler_common.go#L147))
- When a pod is deleted, the volume is unmounted from the pod via `rc.operationExecutor.UnmountVolume()`, which triggers CSI `NodeUnpublishVolume()`.
- **Note:** This only unmounts the volume from the pod, not the device.

#### 4. Device Detach: ControllerUnpublish (DetachVolume)
- **File:** pkg/kubelet/volumemanager/reconciler/reconciler_common.go
- **Function:** `unmountDetachDevices()` ([L283-L301](https://github.com/kubernetes/kubernetes/blob/a78aa47129b8539636eb86a9d00e31b2720fe06b/pkg/kubelet/volumemanager/reconciler/reconciler_common.go#L283-L301))
- If the volume is no longer in the Actual State of World (ASW), calls `rc.operationExecutor.DetachVolume()`, which triggers CSI `ControllerUnpublishVolume()`.
- **Note:** If the device-level unmount (`rc.operationExecutor.UnmountDevice()`) is not triggered, CSI `NodeUnstageVolume()` is **never called**.

#### 5. Summary of Race Condition
- The flow is:
  1. Pod deletion → UnmountVolume (NodeUnpublish)
  2. Volume not in ASW → DetachVolume (ControllerUnpublish)
  3. **NodeUnstage (UnmountDevice) is missing** if device-level unmount is not triggered
- This can result in the CSI NodeUnstage operation **never being called**, leading to potential race conditions, resource leaks, or incomplete cleanup by the CSI driver.

---

## Source Code References
- [reconciler.go#L30](https://github.com/kubernetes/kubernetes/blob/a78aa47129b8539636eb86a9d00e31b2720fe06b/pkg/kubelet/volumemanager/reconciler/reconciler.go#L30)
- [reconciler.go#L37](https://github.com/kubernetes/kubernetes/blob/a78aa47129b8539636eb86a9d00e31b2720fe06b/pkg/kubelet/volumemanager/reconciler/reconciler.go#L37)
- [reconciler_common.go#L267](https://github.com/kubernetes/kubernetes/blob/a78aa47129b8539636eb86a9d00e31b2720fe06b/pkg/kubelet/volumemanager/reconciler/reconciler_common.go#L267)
- [reconciler_common.go#L283-L301](https://github.com/kubernetes/kubernetes/blob/a78aa47129b8539636eb86a9d00e31b2720fe06b/pkg/kubelet/volumemanager/reconciler/reconciler_common.go#L283-L301)

---

## CSI Call Paths

### ControllerUnpublishVolume Call Path

1. **Reconciler triggers DetachVolume**
   - **File:** `operation_executor.go`
   - **Function:** `DetachVolume`
   - **Reference:** Called by the reconciler when a volume needs to be detached.

2. **OperationExecutor calls DetachVolume**
   - **File:** `operation_generator.go`
   - **Function:** `DetachVolume`
   - **Reference:** Generates the detach operation for the volume.

3. **CSI Plugin Detach implementation**
   - **File:** `csi_attacher.go`
   - **Function:** `func (c *csiAttacher) Detach(volumeName string, nodeName types.NodeName) error`
   - **Reference:** This function is called for CSI volumes.

4. **VolumeAttachment deletion triggers external-attacher**
   - **File:** [external-attacher controller (not in k/k, but in external-attacher repo)]
   - **Reference:** The deletion of the VolumeAttachment object is observed by the external CSI attacher sidecar, which then calls the CSI driver's ControllerUnpublishVolume gRPC method.

5. **CSI Driver receives ControllerUnpublishVolume**
   - **File:** CSI driver implementation (out of tree, not in k/k)
   - **Function:** `ControllerUnpublishVolume`
   - **Reference:** The CSI driver executes the actual detach logic.

#### Summary Table

| Step | File & Function | Description |
|------|-----------------|-------------|
| 1 | operation_executor.go:DetachVolume | Reconciler requests detach |
| 2 | operation_generator.go:DetachVolume | Generates detach operation |
| 3 | csi_attacher.go:csiAttacher.Detach | Deletes VolumeAttachment object |
| 4 | external-attacher | Watches for deletion, calls CSI ControllerUnpublishVolume |
| 5 | CSI driver | Executes ControllerUnpublishVolume |

---

### NodeUnstageVolume (Block Mode PVC) Call Path

When kubelet triggers device unstage for a block mode PVC, the following call path is executed:

1. **Reconciler triggers device unmap/unmount**
   - **File:** `pkg/kubelet/volumemanager/reconciler/reconciler.go`
   - **Function:** `reconcile()` → `unmountDetachDevices()`

2. **OperationExecutor handles device unmount**
   - **File:** `pkg/volume/util/operationexecutor/operation_executor.go`
   - **Function:** `UnmountDevice()` (see around line 943)
   - For block volumes, calls `GenerateUnmapDeviceFunc()`

3. **GenerateUnmapDeviceFunc creates the unmap operation**
   - **File:** `pkg/volume/util/operationexecutor/operation_generator.go`
   - **Function:** `GenerateUnmapDeviceFunc()` (see around line 1301)
   - Gets the block volume plugin and unmapper
   - If the plugin implements `CustomBlockVolumeUnmapper`, calls `TearDownDevice(globalMapPath, devicePath)`

4. **CSI block plugin executes TearDownDevice**
   - **File:** `pkg/volume/csi/csi_block.go`
   - **Function:** `TearDownDevice(globalMapPath, devicePath)`
   - Calls `unstageVolumeForBlock(ctx, csiClient, stagingPath)`

5. **CSI block plugin calls NodeUnstageVolume**
   - **File:** `pkg/volume/csi/csi_block.go`
   - **Function:** `unstageVolumeForBlock(ctx, csiClient, stagingPath)`
   - Calls `csiClient.NodeUnstageVolume(ctx, m.volumeID, stagingPath)`

#### Summary Table

| Step | File & Function | Description |
|------|-----------------|-------------|
| 1 | `reconciler.go:reconcile` → `unmountDetachDevices` | Kubelet triggers device unmount |
| 2 | `operation_executor.go:UnmountDevice` | Handles device unmount, calls GenerateUnmapDeviceFunc for block volumes |
| 3 | `operation_generator.go:GenerateUnmapDeviceFunc` | Creates unmap operation, calls TearDownDevice for CSI block plugin |
| 4 | `csi_block.go:TearDownDevice` | CSI plugin executes TearDownDevice, calls unstageVolumeForBlock |
| 5 | `csi_block.go:unstageVolumeForBlock` | Calls NodeUnstageVolume on CSI driver |

---

### NodeUnpublishVolume Call Path

When Kubernetes triggers the CSI NodeUnpublishVolume gRPC, the following call path is executed (for block volumes):

1. **Kubelet triggers unmount for a CSI volume**
   - **File:** `pkg/kubelet/volumemanager/reconciler/reconciler.go`
   - **Function:** `reconcile()` → `unmountVolumes()`
   - The reconciler detects a pod is deleted and triggers unmount for its volumes.

2. **OperationExecutor handles unmount**
   - **File:** `pkg/volume/util/operationexecutor/operation_executor.go`
   - **Function:** `UnmountVolume()`
   - Calls `GenerateUnmountVolumeFunc()` to generate the unmount operation.

3. **OperationGenerator creates unmap operation for block volumes**
   - **File:** `pkg/volume/util/operationexecutor/operation_generator.go`
   - **Function:** `GenerateUnmapVolumeFunc()`
   - Gets the block volume plugin and calls `UnmapPodDevice()` for CSI block volumes.

4. **CSI block plugin executes UnmapPodDevice**
   - **File:** `pkg/volume/csi/csi_block.go`
   - **Function:** `UnmapPodDevice()`
   - Calls `unpublishVolumeForBlock(ctx, csiClient, publishPath)`

5. **CSI block plugin calls NodeUnpublishVolume**
   - **File:** `pkg/volume/csi/csi_block.go`
   - **Function:** `unpublishVolumeForBlock(ctx, csiClient, publishPath)`
   - **Source line:** 400
   - ```go
     if err := csi.NodeUnpublishVolume(ctx, m.volumeID, publishPath); err != nil {
         return errors.New(log("blockMapper.unpublishVolumeForBlock failed: %v", err))
     }
     ```

6. **CSI client issues NodeUnpublishVolume gRPC**
   - **File:** `pkg/volume/csi/csi_client.go`
   - **Function:** `NodeUnpublishVolume(ctx, volID, targetPath)`
   - **Source line:** 358
   - ```go
     req := &csipbv1.NodeUnpublishVolumeRequest{
         VolumeId:   volID,
         TargetPath: targetPath,
     }
     _, err = nodeClient.NodeUnpublishVolume(ctx, req)
     return err
     ```

7. **CSI driver receives NodeUnpublishVolume**
   - **File:** `vendor/github.com/container-storage-interface/spec/lib/go/csi/csi.pb.go`
   - **Function:** `NodeUnpublishVolume(context.Context, *NodeUnpublishVolumeRequest) (*NodeUnpublishVolumeResponse, error)`
   - **Source lines:** 7165, 7119, 7263

#### Summary Table

| Step | File & Function | Description |
|------|-----------------|-------------|
| 1 | `reconciler.go:reconcile` → `unmountVolumes` | Kubelet triggers volume unmount |
| 2 | `operation_executor.go:UnmountVolume` | Handles unmount, calls GenerateUnmapVolumeFunc for block volumes |
| 3 | `operation_generator.go:GenerateUnmapVolumeFunc` | Creates unmap operation, calls UnmapPodDevice for CSI block plugin |
| 4 | `csi_block.go:UnmapPodDevice` | CSI plugin executes UnmapPodDevice, calls unpublishVolumeForBlock |
| 5 | `csi_block.go:unpublishVolumeForBlock` | Calls NodeUnpublishVolume on CSI driver (line 400) |
| 6 | `csi_client.go:NodeUnpublishVolume` | Issues NodeUnpublishVolume gRPC (line 358) |
| 7 | `csi.pb.go:NodeUnpublishVolume` | CSI driver receives NodeUnpublishVolume |


