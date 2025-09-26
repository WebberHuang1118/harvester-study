# VolumeSnapshotContent sourceVolumeMode Field Investigation
 
**Situation:** Missing `sourceVolumeMode` field in VolumeSnapshotContent objects  
**Environment:** Harvester v1.6.0 with Longhorn CSI driver   

## Problem Description

VolumeSnapshotContent objects created with Longhorn CSI driver were missing the `sourceVolumeMode` field in their spec, even though the snapshots were functioning correctly.

### Example Missing Field
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotContent
metadata:
  name: snapcontent-4739abe2-5034-4f49-9525-3bad7d2fdb3a
spec:
  # sourceVolumeMode field was missing here
  deletionPolicy: Delete
  driver: driver.longhorn.io
  source:
    volumeHandle: pvc-f04ace4a-6353-42d6-9b1a-6beeb59b51d0
  # ... rest of spec
```

## Root Cause Analysis

### Key Findings

1. **NOT a Longhorn CSI driver issue** - The Longhorn CSI driver only handles the actual snapshot creation via CSI gRPC calls
2. **External-snapshotter controller responsibility** - The `sourceVolumeMode` field is populated by the external-snapshotter's common snapshot controller
3. **Feature flag dependency** - The field is only set when the `preventVolumeModeConversion` feature is enabled

### Code Investigation

In `/pkg/common-controller/snapshot_controller.go` (lines 757-777):

```go
if ctrl.preventVolumeModeConversion {
    if volume.Spec.VolumeMode != nil {
        snapshotContent.Spec.SourceVolumeMode = volume.Spec.VolumeMode
        klog.V(5).Infof("snapcontent %s has volume mode %s", snapshotContent.Name, *snapshotContent.Spec.SourceVolumeMode)
    }
}
```

This shows the field is conditionally populated based on:
1. `preventVolumeModeConversion` feature flag being enabled
2. Source PersistentVolume having a `VolumeMode` specified

### Version Analysis

From `CHANGELOG-7.0.md`:
> "Enable prevent-volume-mode-conversion feature flag by default. Volume mode change will be rejected when creating a PVC from a VolumeSnapshot unless the AllowVolumeModeChange annotation has been set to true."

**Timeline:**
- **v6.3.3 and earlier**: Feature disabled by default
- **v7.0.0+**: Feature enabled by default

### Environment Analysis

**Harvester v1.6.0 Components:**
- **snapshot-controller**: `v6.3.3` (in kube-system namespace)
- **csi-snapshotter**: `v8.3.0` (Longhorn's sidecar, in longhorn-system namespace)

**Issue:** snapshot-controller v6.3.3 had `preventVolumeModeConversion` disabled by default.

## Solution Applied

### Option 1: Enable Feature Flag (Applied)
Modified the snapshot-controller deployment in `kube-system` namespace:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: snapshot-controller
  namespace: kube-system
spec:
  template:
    spec:
      containers:
      - name: snapshot-controller
        image: registry.k8s.io/sig-storage/snapshot-controller:v6.3.3
        args:
        - --v=5
        - --leader-election=true
        - --prevent-volume-mode-conversion=true  # Added this line
```

### Alternative Option 2: Version Upgrade (Not Applied)
Upgrade to v7.0+ where the feature is enabled by default:

```yaml
containers:
- name: snapshot-controller
  image: registry.k8s.io/sig-storage/snapshot-controller:v8.0.1
  args:
  - --v=5
  - --leader-election=true
  # No need for --prevent-volume-mode-conversion=true (enabled by default)
```

## Results

✅ **Success**: After applying the feature flag, new VolumeSnapshotContent objects now include the `sourceVolumeMode` field.

### Expected Behavior Post-Fix
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotContent
spec:
  sourceVolumeMode: Filesystem  # or Block - now populated!
  deletionPolicy: Delete
  driver: driver.longhorn.io
  # ... rest of spec
```

## Important Notes

### What NOT to Modify
- **Do NOT modify** the Longhorn csi-snapshotter deployment in `longhorn-system` namespace
- The csi-snapshotter is a sidecar controller and doesn't control this feature

### Scope of Changes
- **Retroactive**: Existing VolumeSnapshotContent objects will NOT be updated
- **Prospective**: Only new snapshots created after the fix will have the field populated
- **Compatibility**: No impact on existing snapshot functionality

### Field Purpose
The `sourceVolumeMode` field:
- Indicates the mode of the source volume ("Filesystem" or "Block")
- Is immutable once set
- Used to prevent volume mode conversion during snapshot restore operations
- Alpha field as of the current API version

## Environment Details

### Harvester v1.6.0 Configuration
```yaml
# snapshot-controller (kube-system)
image: registry.k8s.io/sig-storage/snapshot-controller:v6.3.3

# csi-snapshotter (longhorn-system) 
image: longhornio/csi-snapshotter:v8.3.0-20250709
```

### Longhorn CSI Snapshot Example
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotContent
metadata:
  name: snapcontent-4739abe2-5034-4f49-9525-3bad7d2fdb3a
  finalizers:
  - snapshot.storage.kubernetes.io/volumesnapshotcontent-bound-protection
spec:
  deletionPolicy: Delete
  driver: driver.longhorn.io
  source:
    volumeHandle: pvc-f04ace4a-6353-42d6-9b1a-6beeb59b51d0
  volumeSnapshotClassName: longhorn-snapshot
  volumeSnapshotRef:
    apiVersion: snapshot.storage.k8s.io/v1
    kind: VolumeSnapshot
    name: vm-s1-volume-guest-95-k3s-pool1-2dkvn-jjcth-disk-0-758jz
    namespace: default
status:
  creationTime: 1758852418000000000
  readyToUse: true
  restoreSize: 107374182400
  snapshotHandle: snap://pvc-f04ace4a-6353-42d6-9b1a-6beeb59b51d0/snapshot-4739abe2-5034-4f49-9525-3bad7d2fdb3a
```

## Conclusion

This issue was a configuration problem with the external-snapshotter controller, not a bug in the Longhorn CSI driver. The solution was to enable the `preventVolumeModeConversion` feature flag in the snapshot-controller deployment. This demonstrates the importance of understanding the relationship between different components in the Kubernetes CSI snapshot ecosystem.

---

**Resolution Method**: Feature flag enablement  
**Affected Component**: external-snapshotter snapshot-controller  
**Impact**: Cosmetic (field population) - no functional impact on snapshots  
**Testing Status**: ✅ Verified working in Harvester v1.6.0