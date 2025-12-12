# How Longhorn Handles VolumeAttachment (VA) Tickets During Attach, Backup, and Migration

This note summarizes how Longhorn resolves **VolumeAttachment (VA) tickets** when multiple operations compete for the same volume (for example: CSI attach requests, backup creation, and node-to-node migration).

> Scope: These scenarios are based on the Longhorn manager logic referenced in the source links below.

## Terminology (quick reference)
- **CSI ticket**: A VA ticket created to satisfy a Kubernetes/CSI attach request.
- **Backup ticket**: A VA ticket created by the backup controller to ensure the volume/engine is available on the correct node to perform the backup.
- **Detach/attach resolution**: The volume attachment controller may pause or interrupt one ticket so the volume can transition cleanly between nodes.

## Scenario 1: Backup creation ➜ CSI attach requested to a different node
**Flow:** backup creation begins, then a CSI attach request arrives targeting *another node*.

1. The **backup ticket is interrupted**, causing the volume to proceed toward detachment.
   - https://github.com/longhorn/longhorn-manager/blob/0c5eb1d2b77b9a50d39d25b7d7387e2637ed8a4b/controller/volume_attachment_controller.go#L551-L553
   - https://github.com/longhorn/longhorn-manager/blob/0c5eb1d2b77b9a50d39d25b7d7387e2637ed8a4b/controller/volume_attachment_controller.go#L559-L561

2. The **CSI ticket waits** until the volume is **fully detached**.
   - Wait logic:
     - https://github.com/longhorn/longhorn-manager/blob/0c5eb1d2b77b9a50d39d25b7d7387e2637ed8a4b/controller/volume_attachment_controller.go#L650-L653

3. After detachment completes, the controller proceeds to **attach the volume to the node requested by CSI**.
   - Attach decision:
     - https://github.com/longhorn/longhorn-manager/blob/0c5eb1d2b77b9a50d39d25b7d7387e2637ed8a4b/controller/volume_attachment_controller.go#L668-L669

## Scenario 2: CSI attach ➜ Backup creation
**Flow:** CSI attach completes first, then a backup is requested.

1. After a successful CSI attach, the volume’s `Status.OwnerID` is set to the attached node.
   - https://github.com/longhorn/longhorn-manager/blob/0c5eb1d2b77b9a50d39d25b7d7387e2637ed8a4b/controller/volume_controller.go#L4665

2. The backup controller creates a **backup ticket** that requests the volume to be attached on the node recorded in `Status.OwnerID`.

3. In this case, **CSI attachment and backup execution use the engine on the same node**, avoiding a node transition.

## Scenario 3: CSI attach (node A) ➜ CSI attach (node B)
**Flow:** a second CSI attach request targets a different node while the volume is already attached.

- Longhorn triggers **volume live migration**.
  - https://github.com/longhorn/longhorn-manager/blob/0c5eb1d2b77b9a50d39d25b7d7387e2637ed8a4b/controller/volume_attachment_controller.go#L379-L400
