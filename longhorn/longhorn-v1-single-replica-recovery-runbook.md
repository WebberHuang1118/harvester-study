# Longhorn V1 Single-Replica Recovery Runbook for Harvester

## Purpose

This runbook describes how to recover data from a **faulted Longhorn V1 volume with only one remaining replica** on Harvester.

It covers two cases:

1. **V1 volume without a backing image**
2. **V1 volume with a backing image**

The recovery process:

1. Stops the workload.
2. Locates the remaining replica.
3. Copies the replica to healthy storage.
4. Launches a temporary Longhorn engine from the copied data.
5. Exposes a recovery block device under `/dev/longhorn/`.
6. Copies or mounts the recovered data read-only.

> This is a last-resort data-salvage procedure. It does not guarantee application-consistent data, especially when the original failure was caused by a full disk or interrupted writes.

---

## References

- [Longhorn: Exporting a Volume from a Single Replica](https://longhorn.io/docs/latest/advanced-resources/data-recovery/export-from-replica/)
- [Longhorn: Backing Image](https://longhorn.io/docs/latest/advanced-resources/backing-image/backing-image/)

---

## Scope and prerequisites

This runbook applies only when:

- The volume uses the **Longhorn V1 Data Engine**.
- The replica directory still exists.
- The replica files are readable.
- The VM or workload can be stopped.
- Healthy storage is available for a recovery copy.
- The exact or compatible Longhorn engine image is available.

This procedure does **not** apply directly to:

- Longhorn V2/SPDK volumes.
- Missing or unreadable replica directories.
- A backing-image volume when the original backing image cannot be recovered.
- Volumes whose snapshot chain is incomplete or corrupted beyond what the engine can open.

---

# Safety rules

Before starting:

- Stop the VM or workload.
- Do not delete the Longhorn Volume CR.
- Do not delete the only Replica CR.
- Do not trigger snapshot purge.
- Do not delete files from the full Longhorn disk.
- Do not run recovery directly against the original replica.
- Copy the replica to healthy storage first.
- Do not run filesystem repair against the only recovery copy.
- Mount recovered filesystems read-only first.
- Preserve all metadata and logs.

For a volume created from a backing image:

- The replica delta files are not necessarily a complete volume.
- The exact backing-image file is also required.
- The backing image must be supplied to the Longhorn replica process with `--backing-file`.

---

# Variables used in this runbook

Replace the following placeholders with values from your environment:

```bash
export VM_NAMESPACE="<vm-namespace>"
export VM_NAME="<vm-name>"
export PVC_NAME="<vm-disk-pvc>"

export RECOVERY_NODE="<node-containing-healthy-recovery-storage>"
export RECOVERY_DISK="/mnt/healthy-disk"
```

Example:

```bash
export VM_NAMESPACE="default"
export VM_NAME="windows-vm"
export PVC_NAME="windows-vm-disk-0"

export RECOVERY_NODE="harvester-node-2"
export RECOVERY_DISK="/mnt/healthy-disk"
```

---

# Phase 1: Identify the volume and remaining replica

## 1. Get the Longhorn volume name

```bash
export VOLUME_NAME=$(
  kubectl -n "$VM_NAMESPACE" get pvc "$PVC_NAME" \
    -o jsonpath='{.spec.volumeName}'
)

echo "$VOLUME_NAME"
```

Expected format:

```text
pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

---

## 2. Stop the VM

Using `virtctl`:

```bash
virtctl stop -n "$VM_NAMESPACE" "$VM_NAME"
```

Or stop the VM through the Harvester UI.

Verify that the VMI no longer exists:

```bash
kubectl -n "$VM_NAMESPACE" get vmi "$VM_NAME"
```

Expected:

```text
Error from server (NotFound)
```

Do not continue while the VMI is still running.

---

## 3. Confirm the data engine

```bash
export DATA_ENGINE=$(
  kubectl -n longhorn-system \
    get volumes.longhorn.io "$VOLUME_NAME" \
    -o jsonpath='{.spec.dataEngine}'
)

echo "Data engine: ${DATA_ENGINE}"
```

Expected:

```text
v1
```

On older Longhorn releases, the field may be empty for legacy V1 volumes. Confirm that the replica is directory-based and contains:

```text
volume.meta
volume-head-*.img
volume-snap-*.img
```

Stop if the volume uses:

```text
v2
```

---

## 4. Check whether the volume uses a backing image

```bash
export BACKING_IMAGE=$(
  kubectl -n longhorn-system \
    get volumes.longhorn.io "$VOLUME_NAME" \
    -o jsonpath='{.spec.backingImage}'
)

echo "Backing image: ${BACKING_IMAGE:-<none>}"
```

Decision:

```text
BACKING_IMAGE is empty     -> Use Case A
BACKING_IMAGE is non-empty -> Use Case B
```

---

## 5. Find replicas for the volume

This command requires `jq`:

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o json |
  jq -r --arg volume "$VOLUME_NAME" '
    .items[]
    | select(.spec.volumeName == $volume)
    | [
        .metadata.name,
        .spec.nodeID,
        .spec.diskID,
        .spec.diskPath,
        .spec.dataDirectoryName,
        .spec.backingImage,
        .status.currentState,
        .status.currentImage
      ]
    | @tsv
  '
```

Confirm that there is only one relevant replica.

Set the replica name:

```bash
export REPLICA_NAME=$(
  kubectl -n longhorn-system get replicas.longhorn.io -o json |
    jq -r --arg volume "$VOLUME_NAME" '
      .items[]
      | select(.spec.volumeName == $volume)
      | .metadata.name
    '
)

echo "$REPLICA_NAME"
```

---

## 6. Collect replica location and engine image

```bash
export REPLICA_NODE=$(
  kubectl -n longhorn-system \
    get replicas.longhorn.io "$REPLICA_NAME" \
    -o jsonpath='{.spec.nodeID}'
)

export DISK_ID=$(
  kubectl -n longhorn-system \
    get replicas.longhorn.io "$REPLICA_NAME" \
    -o jsonpath='{.spec.diskID}'
)

export DISK_PATH=$(
  kubectl -n longhorn-system \
    get replicas.longhorn.io "$REPLICA_NAME" \
    -o jsonpath='{.spec.diskPath}'
)

export DATA_DIRECTORY=$(
  kubectl -n longhorn-system \
    get replicas.longhorn.io "$REPLICA_NAME" \
    -o jsonpath='{.spec.dataDirectoryName}'
)

export ENGINE_IMAGE=$(
  kubectl -n longhorn-system \
    get replicas.longhorn.io "$REPLICA_NAME" \
    -o jsonpath='{.status.currentImage}'
)

printf 'Volume:         %s\n' "$VOLUME_NAME"
printf 'Replica:        %s\n' "$REPLICA_NAME"
printf 'Replica node:   %s\n' "$REPLICA_NODE"
printf 'Disk ID:        %s\n' "$DISK_ID"
printf 'Disk path:      %s\n' "$DISK_PATH"
printf 'Data directory: %s\n' "$DATA_DIRECTORY"
printf 'Engine image:   %s\n' "$ENGINE_IMAGE"
```

If `ENGINE_IMAGE` is empty, use the cluster default as a fallback:

```bash
export ENGINE_IMAGE=$(
  kubectl -n longhorn-system \
    get settings.longhorn.io default-engine-image \
    -o jsonpath='{.value}'
)

echo "$ENGINE_IMAGE"
```

Using the image recorded by the replica is preferred.

---

## 7. Save Kubernetes metadata

```bash
export METADATA_DIR="./longhorn-recovery-metadata/${VOLUME_NAME}"

mkdir -p "$METADATA_DIR"

kubectl -n "$VM_NAMESPACE" get pvc "$PVC_NAME" -o yaml \
  > "${METADATA_DIR}/pvc.yaml"

kubectl get pv "$VOLUME_NAME" -o yaml \
  > "${METADATA_DIR}/pv.yaml"

kubectl -n longhorn-system \
  get volumes.longhorn.io "$VOLUME_NAME" -o yaml \
  > "${METADATA_DIR}/volume.yaml"

kubectl -n longhorn-system \
  get replicas.longhorn.io "$REPLICA_NAME" -o yaml \
  > "${METADATA_DIR}/replica.yaml"

if [ -n "$BACKING_IMAGE" ]; then
  kubectl -n longhorn-system \
    get backingimages.longhorn.io "$BACKING_IMAGE" -o yaml \
    > "${METADATA_DIR}/backing-image.yaml"
fi
```

---

# Phase 2: Copy the replica to healthy storage

Run the following commands on the node containing the original replica.

```bash
ssh <user>@"$REPLICA_NODE"
sudo -i
```

Set the values again on that node:

```bash
export VOLUME_NAME="pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export DISK_PATH="<longhorn-disk-path>"
export DATA_DIRECTORY="<replica-data-directory-name>"

export SOURCE_REPLICA="${DISK_PATH}/replicas/${DATA_DIRECTORY}"
export RECOVERY_DISK="/mnt/healthy-disk"
export RECOVERY_ROOT="${RECOVERY_DISK}/longhorn-recovery/${VOLUME_NAME}"
export REPLICA_COPY="${RECOVERY_ROOT}/replica"
```

---

## 1. Verify the original replica

```bash
test -d "$SOURCE_REPLICA"
test -f "$SOURCE_REPLICA/volume.meta"

ls -lah "$SOURCE_REPLICA"
cat "$SOURCE_REPLICA/volume.meta"
```

Expected files may include:

```text
volume.meta
volume-head-*.img
volume-head-*.img.meta
volume-snap-*.img
volume-snap-*.img.meta
revision.counter
```

---

## 2. Confirm the original replica is not in use

```bash
lsof +D "$SOURCE_REPLICA"
```

No output is expected.

You can also check:

```bash
fuser -vm "$SOURCE_REPLICA"
```

Do not continue if a Longhorn process is still using the directory.

---

## 3. Confirm that the destination is healthy and separate

```bash
df -h "$DISK_PATH"
df -h "$RECOVERY_DISK"

findmnt "$DISK_PATH"
findmnt "$RECOVERY_DISK"
```

The destination should not be the same full filesystem.

Inspect allocated and apparent replica size:

```bash
du -sh "$SOURCE_REPLICA"
du -sh --apparent-size "$SOURCE_REPLICA"
```

---

## 4. Copy the replica and preserve sparse files

```bash
mkdir -p "$REPLICA_COPY"

rsync -aHAXS \
  --numeric-ids \
  --info=progress2 \
  "$SOURCE_REPLICA/" \
  "$REPLICA_COPY/"

sync
```

Verify the copy:

```bash
rsync -aHAXSni \
  --numeric-ids \
  "$SOURCE_REPLICA/" \
  "$REPLICA_COPY/"
```

No output is expected.

---

## 5. Read the volume size from the copied metadata

```bash
cat "$REPLICA_COPY/volume.meta"
```

When `jq` is installed:

```bash
export VOLUME_SIZE=$(
  jq -r '.Size' "$REPLICA_COPY/volume.meta"
)

echo "$VOLUME_SIZE"
```

Without `jq`:

```bash
export VOLUME_SIZE=$(
  grep -oE '"Size"[[:space:]]*:[[:space:]]*[0-9]+' \
    "$REPLICA_COPY/volume.meta" |
  grep -oE '[0-9]+'
)

echo "$VOLUME_SIZE"
```

Example:

```text
107374182400
```

---

## 6. Use a unique recovery frontend name

```bash
export RECOVERY_NAME="${VOLUME_NAME}-recovery"

echo "$RECOVERY_NAME"
```

Expected recovery device:

```text
/dev/longhorn/${RECOVERY_NAME}
```

Using a different name avoids colliding with an existing `/dev/longhorn/<original-volume-name>` device.

---

# Case A: V1 volume without a backing image

Use this case when:

```bash
test -z "$BACKING_IMAGE"
```

succeeds.

## 1. Create the recovery Pod manifest

Create `/tmp/longhorn-recovery-no-bi.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: longhorn-recovery
  namespace: longhorn-system
spec:
  nodeName: "<RECOVERY_NODE>"
  hostPID: true
  restartPolicy: Never

  tolerations:
    - operator: Exists

  containers:
    - name: engine
      image: "<ENGINE_IMAGE>"
      imagePullPolicy: IfNotPresent

      securityContext:
        privileged: true

      command:
        - launch-simple-longhorn

      args:
        - "<RECOVERY_NAME>"
        - "<VOLUME_SIZE>"

      volumeMounts:
        - name: dev
          mountPath: /host/dev

        - name: proc
          mountPath: /host/proc

        - name: replica
          mountPath: /volume

  volumes:
    - name: dev
      hostPath:
        path: /dev
        type: Directory

    - name: proc
      hostPath:
        path: /proc
        type: Directory

    - name: replica
      hostPath:
        path: "<REPLICA_COPY>"
        type: Directory
```

Example substitutions:

```yaml
spec:
  nodeName: "harvester-node-2"
```

```yaml
image: "longhornio/longhorn-engine:v1.10.1"
```

```yaml
args:
  - "pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx-recovery"
  - "107374182400"
```

```yaml
hostPath:
  path: "/mnt/healthy-disk/longhorn-recovery/pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/replica"
```

---

## 2. Launch the Pod

When the Kubernetes API is working:

```bash
kubectl apply -f /tmp/longhorn-recovery-no-bi.yaml
```

Verify scheduling:

```bash
kubectl -n longhorn-system \
  get pod longhorn-recovery -o wide
```

The `NODE` column must match `<RECOVERY_NODE>`.

Follow logs:

```bash
kubectl -n longhorn-system \
  logs -f longhorn-recovery
```

---

## 3. RKE2 static-Pod alternative

Use this only when the Kubernetes control plane cannot create a normal Pod.

On the recovery node:

```bash
sudo cp /tmp/longhorn-recovery-no-bi.yaml \
  /var/lib/rancher/rke2/agent/pod-manifests/longhorn-recovery.yaml
```

Do not use both the normal Pod and static-Pod methods at the same time.

---

# Case B: V1 volume with a backing image

Use this case when:

```bash
test -n "$BACKING_IMAGE"
```

succeeds.

A backing image is the initial/base layer of the volume. The replica files contain delta changes above that base. Therefore, the copied replica directory alone may not contain every block of the complete volume.

The exact backing image must be copied and supplied to the replica engine.

---

## 1. Get the backing-image UUID and checksum

Run from a machine with `kubectl` access:

```bash
export BACKING_IMAGE_UUID=$(
  kubectl -n longhorn-system \
    get backingimages.longhorn.io "$BACKING_IMAGE" \
    -o jsonpath='{.status.uuid}'
)

export EXPECTED_CHECKSUM=$(
  kubectl -n longhorn-system \
    get backingimages.longhorn.io "$BACKING_IMAGE" \
    -o jsonpath='{.status.checksum}'
)

if [ -z "$EXPECTED_CHECKSUM" ]; then
  export EXPECTED_CHECKSUM=$(
    kubectl -n longhorn-system \
      get backingimages.longhorn.io "$BACKING_IMAGE" \
      -o jsonpath='{.spec.checksum}'
  )
fi

printf 'Backing image: %s\n' "$BACKING_IMAGE"
printf 'UUID:          %s\n' "$BACKING_IMAGE_UUID"
printf 'Checksum:      %s\n' "$EXPECTED_CHECKSUM"
```

---

## 2. Locate the backing-image file

On the node containing a ready backing-image copy:

```bash
export BACKING_IMAGE="<backing-image-name>"
export BACKING_IMAGE_UUID="<backing-image-uuid>"
export DISK_PATH="<longhorn-disk-path>"

export SOURCE_BACKING_FILE="${DISK_PATH}/backing-images/${BACKING_IMAGE}-${BACKING_IMAGE_UUID}/backing"

echo "$SOURCE_BACKING_FILE"
```

Verify:

```bash
test -f "$SOURCE_BACKING_FILE"
ls -lh "$SOURCE_BACKING_FILE"
```

If the file is not on the replica disk, search other Longhorn disks:

```bash
find /var/lib/harvester /mnt \
  -type f \
  -path "*/backing-images/${BACKING_IMAGE}-${BACKING_IMAGE_UUID}/backing" \
  2>/dev/null
```

Do not continue until the exact backing-image file is found.

---

## 3. Verify the backing-image checksum

```bash
export ACTUAL_CHECKSUM=$(
  sha512sum "$SOURCE_BACKING_FILE" |
    awk '{print $1}'
)

printf 'Expected: %s\n' "$EXPECTED_CHECKSUM"
printf 'Actual:   %s\n' "$ACTUAL_CHECKSUM"
```

Validate:

```bash
if [ -n "$EXPECTED_CHECKSUM" ] &&
   [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
  echo "Backing-image checksum mismatch"
  exit 1
fi
```

---

## 4. Copy the backing image

```bash
export BACKING_COPY_DIR="${RECOVERY_ROOT}/backing"
export BACKING_COPY="${BACKING_COPY_DIR}/backing"

mkdir -p "$BACKING_COPY_DIR"

rsync -aHAXS \
  --numeric-ids \
  --info=progress2 \
  "$SOURCE_BACKING_FILE" \
  "$BACKING_COPY"

sync
```

Verify:

```bash
sha512sum "$SOURCE_BACKING_FILE"
sha512sum "$BACKING_COPY"
```

The two checksums must match.

When available:

```bash
qemu-img info "$BACKING_COPY"
```

Longhorn V1 backing images may use RAW or QCOW2 format.

---

## 5. Why the normal launcher needs modification

The standard launcher accepts:

```text
launch-simple-longhorn <volume-name> <volume-size> [frontend]
```

The third argument is the frontend, not a backing-image path.

The launcher starts a replica similar to:

```bash
longhorn replica /volume/ --size <size>
```

For a backing-image volume, it must instead start the replica with:

```bash
longhorn replica /volume/ \
  --size <size> \
  --backing-file /backing/backing
```

The following manifest copies and modifies the launcher only inside the temporary recovery container.

---

## 6. Create the backing-image recovery manifest

Create `/tmp/longhorn-recovery-with-bi.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: longhorn-recovery
  namespace: longhorn-system
spec:
  nodeName: "<RECOVERY_NODE>"
  hostPID: true
  restartPolicy: Never

  tolerations:
    - operator: Exists

  containers:
    - name: engine
      image: "<ENGINE_IMAGE>"
      imagePullPolicy: IfNotPresent

      securityContext:
        privileged: true

      env:
        - name: RECOVERY_NAME
          value: "<RECOVERY_NAME>"

        - name: VOLUME_SIZE
          value: "<VOLUME_SIZE>"

      command:
        - /bin/bash
        - -c

      args:
        - |
          set -euo pipefail

          test -f /volume/volume.meta
          test -f /backing/backing
          test -w /volume

          LAUNCHER="$(command -v launch-simple-longhorn)"

          if [ -z "${LAUNCHER}" ]; then
            echo "launch-simple-longhorn was not found"
            exit 1
          fi

          echo "Original launcher: ${LAUNCHER}"

          MATCH_COUNT="$(
            grep -c 'replica /volume/' "${LAUNCHER}" || true
          )"

          if [ "${MATCH_COUNT}" -ne 1 ]; then
            echo "Unexpected launch-simple-longhorn format"
            echo "Refusing to modify the launcher automatically"
            cat "${LAUNCHER}"
            exit 1
          fi

          sed \
            '/replica \/volume\// s|$| "--backing-file" /backing/backing|' \
            "${LAUNCHER}" \
            > /tmp/launch-simple-longhorn-bi

          chmod +x /tmp/launch-simple-longhorn-bi

          echo "Modified replica command:"
          grep -n 'replica /volume/' \
            /tmp/launch-simple-longhorn-bi

          exec /tmp/launch-simple-longhorn-bi \
            "${RECOVERY_NAME}" \
            "${VOLUME_SIZE}"

      volumeMounts:
        - name: dev
          mountPath: /host/dev

        - name: proc
          mountPath: /host/proc

        - name: replica
          mountPath: /volume

        - name: backing
          mountPath: /backing
          readOnly: true

  volumes:
    - name: dev
      hostPath:
        path: /dev
        type: Directory

    - name: proc
      hostPath:
        path: /proc
        type: Directory

    - name: replica
      hostPath:
        path: "<REPLICA_COPY>"
        type: Directory

    - name: backing
      hostPath:
        path: "<BACKING_COPY_DIR>"
        type: Directory
```

The safety check refuses to modify the launcher when its structure does not match the expected version.

Before applying the manifest, verify the exact engine image's launcher when possible:

```bash
kubectl -n longhorn-system run inspect-engine-launcher \
  --restart=Never \
  --image="$ENGINE_IMAGE" \
  --command -- \
  /bin/bash -c 'cat "$(command -v launch-simple-longhorn)"'
```

Review the output, then delete the inspection Pod:

```bash
kubectl -n longhorn-system delete pod inspect-engine-launcher
```

---

## 7. Launch the backing-image recovery Pod

```bash
kubectl apply -f /tmp/longhorn-recovery-with-bi.yaml
```

Verify placement:

```bash
kubectl -n longhorn-system \
  get pod longhorn-recovery -o wide
```

Follow logs:

```bash
kubectl -n longhorn-system \
  logs -f longhorn-recovery
```

Confirm the logs show:

```text
--backing-file /backing/backing
```

If the launcher format is different, the Pod should stop before opening the replica. Review the printed launcher and adapt the version-specific command manually.

---

# Phase 3: Validate and export the recovered block device

Run these commands on the recovery node.

```bash
export RECOVERY_NAME="<recovery-name>"
export RECOVERY_DEVICE="/dev/longhorn/${RECOVERY_NAME}"
```

---

## 1. Confirm that the block device exists

```bash
ls -l /dev/longhorn
test -b "$RECOVERY_DEVICE"
```

Resolve the real device:

```bash
export REAL_DEVICE=$(readlink -f "$RECOVERY_DEVICE")

echo "$REAL_DEVICE"
lsblk -f "$REAL_DEVICE"
```

---

## 2. Inspect the disk and partition table

For a Harvester VM disk:

```bash
fdisk -l "$REAL_DEVICE"

lsblk \
  -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS \
  "$REAL_DEVICE"
```

Ask the kernel to discover partitions:

```bash
partprobe "$REAL_DEVICE"
udevadm settle

lsblk -f "$REAL_DEVICE"
```

A VM disk normally contains one or more partitions. Do not mount the whole disk when partitions are present.

---

## 3. Recommended: export the complete recovered disk first

```bash
export OUTPUT_DIR="${RECOVERY_ROOT}/output"

mkdir -p "$OUTPUT_DIR"

dd \
  if="$RECOVERY_DEVICE" \
  of="${OUTPUT_DIR}/${RECOVERY_NAME}.raw" \
  bs=16M \
  status=progress \
  conv=sparse

sync
```

Create a checksum:

```bash
sha256sum "${OUTPUT_DIR}/${RECOVERY_NAME}.raw" \
  | tee "${OUTPUT_DIR}/${RECOVERY_NAME}.raw.sha256"
```

Preserve this raw image unchanged.

---

## 4. Mount a Linux filesystem read-only

Set the partition shown by `lsblk`:

```bash
export RECOVERY_PARTITION="/dev/sdX1"
```

### ext4

```bash
mkdir -p /mnt/recovered-volume

mount \
  -o ro,noload \
  "$RECOVERY_PARTITION" \
  /mnt/recovered-volume
```

### XFS

```bash
mkdir -p /mnt/recovered-volume

mount \
  -o ro,norecovery \
  "$RECOVERY_PARTITION" \
  /mnt/recovered-volume
```

### NTFS

```bash
mkdir -p /mnt/recovered-volume

mount \
  -t ntfs3 \
  -o ro \
  "$RECOVERY_PARTITION" \
  /mnt/recovered-volume
```

Inspect files:

```bash
find /mnt/recovered-volume -maxdepth 2 -ls |
  head -100
```

Do not run modifying repair commands against the only raw export or recovery copy.

---

# Phase 4: Cleanup

## 1. Save recovery logs

Before deleting the Pod:

```bash
kubectl -n longhorn-system \
  logs longhorn-recovery \
  > "${METADATA_DIR}/recovery-pod.log"
```

---

## 2. Unmount the filesystem

```bash
umount /mnt/recovered-volume
```

Verify:

```bash
lsblk -f "$REAL_DEVICE"
```

---

## 3. Stop the recovery Pod

For a normal Kubernetes Pod:

```bash
kubectl -n longhorn-system \
  delete pod longhorn-recovery
```

For an RKE2 static Pod:

```bash
sudo rm -f \
  /var/lib/rancher/rke2/agent/pod-manifests/longhorn-recovery.yaml
```

Wait for cleanup:

```bash
sleep 10

ls -l /dev/longhorn
ps aux | grep -E 'longhorn|tgtd' |
  grep "$RECOVERY_NAME"
```

A dangling recovery symlink may remain. Remove it only after confirming that the recovery engine and underlying block device no longer exist:

```bash
if [ -L "/dev/longhorn/${RECOVERY_NAME}" ] &&
   [ ! -e "/dev/longhorn/${RECOVERY_NAME}" ]; then
  rm -f "/dev/longhorn/${RECOVERY_NAME}"
fi
```

---

# Data to preserve

Keep the following until recovery has been fully validated:

```text
longhorn-recovery/<volume>/replica/
longhorn-recovery/<volume>/backing/       # Backing-image case
longhorn-recovery/<volume>/output/*.raw
longhorn-recovery/<volume>/output/*.sha256
saved PVC/PV/Volume/Replica YAML
BackingImage YAML                         # Backing-image case
recovery Pod manifest
recovery Pod logs
```

---

# Troubleshooting

## Recovery Pod is scheduled on the wrong node

Check:

```bash
kubectl -n longhorn-system \
  get pod longhorn-recovery -o wide
```

The manifest must include:

```yaml
spec:
  nodeName: "<node-containing-the-copied-data>"
```

The host path must exist on that same node.

---

## Pod reports that `/volume/volume.meta` is missing

Check the host path:

```bash
ls -lah "$REPLICA_COPY"
```

The path mounted as `/volume` must directly contain:

```text
volume.meta
volume-head-*.img
```

Do not mount the parent directory above the actual replica directory.

---

## Pod starts but `/dev/longhorn/<name>` does not appear

Check logs:

```bash
kubectl -n longhorn-system \
  logs longhorn-recovery
```

Check node requirements:

```bash
iscsiadm --version
lsmod | grep iscsi
```

Inspect processes on the recovery node:

```bash
ps aux | grep -E 'longhorn|tgtd'
```

---

## Backing-image recovery reports an unsupported format

Check:

```bash
qemu-img info "$BACKING_COPY"
```

Longhorn V1 supports RAW and QCOW2 backing images.

Make sure the copied file is the actual:

```text
<disk-path>/backing-images/<name>-<UUID>/backing
```

and not a metadata or temporary file.

---

## Backing image is missing

Complete recovery cannot be assumed because unchanged blocks may exist only in the backing image.

Possible recovery sources:

- Another ready backing-image copy on a different Longhorn disk.
- The original upload file.
- The original download URL.
- A backing-image backup.
- The source volume used to export the backing image.

For an uploaded backing image, if every Longhorn copy and the original upload are gone, Longhorn cannot automatically recreate it.

---

## Filesystem will not mount read-only

Do not immediately run a modifying repair command.

First preserve the complete recovered disk:

```bash
dd \
  if="$RECOVERY_DEVICE" \
  of="${OUTPUT_DIR}/${RECOVERY_NAME}.raw" \
  bs=16M \
  status=progress \
  conv=sparse
```

Then make another copy of the raw image and perform repair against the duplicate.

---

# Recovery decision table

| Condition | Recovery approach |
|---|---|
| V1 volume without backing image | Standard `launch-simple-longhorn` |
| V1 volume with available backing image | Modified launcher with `--backing-file` |
| V1 volume with missing backing image | Complete recovery cannot be assumed |
| Uploaded BI and all copies are gone | Original upload is required |
| V2/SPDK volume | This runbook does not apply |
| Encrypted volume | Original encryption secret is also required |
| Snapshot chain is incomplete | Recovery may fail or be partial |
| Writes failed due to a full disk | Latest writes may be missing or inconsistent |

---

# Final checklist

Before launching recovery:

```text
[ ] VM is stopped
[ ] VMI no longer exists
[ ] Volume uses V1
[ ] Only replica has not been deleted
[ ] Original replica is no longer in use
[ ] Replica has been copied with sparse-file preservation
[ ] Recovery copy is on healthy storage
[ ] Recovery Pod is pinned to the node containing the copy
[ ] Exact or compatible Longhorn engine image is used
[ ] Volume size was read from the copied volume.meta
[ ] A unique recovery frontend name is used
[ ] Backing image was copied and checksum-verified, when applicable
[ ] Recovery is performed against copies rather than original data
[ ] Recovered filesystem will be mounted read-only first
[ ] Complete raw disk will be exported before repair attempts
```
