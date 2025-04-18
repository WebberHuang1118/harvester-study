# PVC Annotation with CSI Creation Flow

## Motivation
The incorrect validation logic in the Longhorn (LH) PVC validator causes oversized volumes to remain stuck in the Pending state. For more details, refer to the related issue: [Harvester Issue #8096](https://github.com/harvester/harvester/issues/8096#issuecomment-2814328640).

## Overview of the CSI Provisioner Behavior

### Annotation and Status Updates
In the CSI implementation, the external-provisioner relies on annotations and status updates on the PVC to determine whether provisioning should proceed. Key behaviors include:

- **ShouldProvision Method**: Checks annotations like `annStorageProvisioner` to ensure the PVC is intended for this provisioner. [Code Reference](https://github.com/kubernetes-csi/external-provisioner/blob/12a344a40072d655cb9374a93483305f1a1be557/pkg/controller/controller.go#L1398-L1407)
- **Provision Method**: Requires the PVC to have valid annotations and a Pending phase to proceed with volume creation. [Code Reference](https://github.com/kubernetes-csi/external-provisioner/blob/12a344a40072d655cb9374a93483305f1a1be557/pkg/controller/controller.go#L785-L800)

### Issues Leading to PVC Stuck in Pending
1. **Webhook Rejections**:
   - The webhook may block updates that add the `annStorageProvisioner` annotation or other metadata required by the CSI provisioner.
   - This prevents the PVC from transitioning to a state where the CSI provisioner can act on it.

2. **Provisioner Ownership Failure**:
   - The provisioner may fail to acquire ownership of the PVC (e.g., via the `checkNode` method) because the PVC remains in an invalid state.

### Logs and Error Messages
The CSI provisioner logs may display errors such as:
- "PVC not valid for provisioning"
- "PVC update failed"

These errors indicate that the provisioner cannot proceed due to the webhook's rejection of updates.

### Exponential Backoff
The CSI provisioner employs an exponential backoff mechanism when encountering errors during provisioning. If the webhook consistently rejects updates, the provisioner will retry indefinitely without success, leaving the PVC in the Pending state.

## Conclusion
The webhook's incorrect validation logic creates a bottleneck, preventing the PVC from being updated with the necessary metadata or annotations. Consequently, the CSI provisioner fails to proceed with provisioning, leaving the PVC stuck in the Pending state indefinitely.