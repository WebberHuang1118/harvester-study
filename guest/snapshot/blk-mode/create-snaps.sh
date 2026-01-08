#!/bin/bash

# Variables
PVC_NAME="blk-vol"
NAMESPACE="default"  # Change this to your target namespace
VOLUME_SNAPSHOT_CLASS="harvester-snapshot"  # Change this to your VolumeSnapshotClass

# Create 10 VolumeSnapshot resources
for i in {1..10}; do
  SNAPSHOT_NAME="${PVC_NAME}-snapshot-${i}"
  
  cat << YAML | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${NAMESPACE}
spec:
  source:
    persistentVolumeClaimName: ${PVC_NAME}
  volumeSnapshotClassName: ${VOLUME_SNAPSHOT_CLASS}
YAML

  echo "Created VolumeSnapshot: ${SNAPSHOT_NAME}"
done

echo "Successfully created 10 VolumeSnapshots from PVC: ${PVC_NAME}"