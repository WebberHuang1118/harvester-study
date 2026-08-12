# LVM and Device-Mapper Troubleshooting Runbook

This runbook collects useful commands for inspecting LVM, dm-thin pools, device-mapper mappings, stale device holders, and damaged or missing PV/VG metadata.

> **Warning**
>
> Commands such as `wipefs`, `blkdiscard`, `pvcreate`, `vgcreate`, `lvconvert --repair`, `lvremove`, `vgremove`, and `dmsetup remove` are destructive or can make active storage unavailable.
>
> Confirm the target device and stop all workloads using it before running destructive commands.

---

## 1. Set Common Variables

```bash
DEV=/dev/nvme0n1
VG=vg1
THINPOOL=vg1-thinpool
```

---

## 2. Basic LVM Inventory

### List physical volumes

```bash
pvs
```

More detail:

```bash
pvs -o pv_name,pv_uuid,vg_name,pv_size,pv_free,pv_attr
```

### List volume groups

```bash
vgs
```

More detail:

```bash
vgs -o vg_name,vg_uuid,vg_attr,vg_size,vg_free,pv_count,lv_count
```

### List logical volumes

```bash
lvs
```

Useful dm-thin view:

```bash
lvs -a \
  -o lv_name,vg_name,lv_attr,lv_size,pool_lv,origin,data_percent,metadata_percent,devices
```

Compact dm-thin view:

```bash
lvs -a -o+lv_name,data_percent,metadata_percent,lv_size,pool_lv,lv_attr
```

Watch usage continuously:

```bash
watch -n1 \
  'lvs -a -o lv_name,vg_name,lv_attr,lv_size,pool_lv,origin,data_percent,metadata_percent'
```

---

## 3. Understand Thin-LV and Thin-Pool Usage

For a thin LV:

```bash
lvs -o lv_name,lv_size,pool_lv,data_percent
```

Interpretation:

- Thin-LV `Data%` is the percentage of the virtual LV address space that has mapped thin-pool chunks.
- Thin-pool `Data%` is the percentage of the entire pool data area that is allocated.
- A small LV can show `Data%=100` while the pool itself remains nearly empty.

Example:

```text
LV          LSize  Data%
pvc-...     2.20g  100.00

LV             LSize  Data%
vg1-thinpool    1.64t    0.13
```

This means the 2.2 GiB LV is fully mapped, but it consumes only about 0.13% of the 1.64 TiB pool.

### Check thin-pool zeroing

```bash
lvs -o lv_name,vg_name,zero,lv_attr "$VG"
```

In `lv_attr`, `z` means zeroing is enabled:

```text
twi-aotz--
       ^
       zeroing enabled
```

Check the device-mapper table:

```bash
dmsetup table "${VG}-${THINPOOL}" 2>/dev/null
dmsetup table "${VG}-${THINPOOL}-tpool" 2>/dev/null
```

If zeroing is disabled, the table normally includes:

```text
skip_block_zeroing
```

Disable zeroing for future allocations:

```bash
lvchange --zero n "$VG/$THINPOOL"
```

Enable it again:

```bash
lvchange --zero y "$VG/$THINPOOL"
```

> Zeroing does not allocate every thin chunk by itself. It only zeroes a chunk after that chunk has been allocated.

---

## 4. Device-Mapper Inventory and Dependency Tree

### Show all mappings as a tree

```bash
dmsetup ls --tree
```

Example structure:

```text
vg1-pvc--...
 └─vg1-vg1--thinpool-tpool
    ├─vg1-vg1--thinpool_tdata
    │  └─nvme0n1
    └─vg1-vg1--thinpool_tmeta
       └─nvme0n1
```

### Show mapping tables

```bash
dmsetup table
```

For one mapping:

```bash
dmsetup table <mapping-name>
```

### Show runtime status

```bash
dmsetup status
```

For one mapping:

```bash
dmsetup status <mapping-name>
```

### Show open counts

```bash
dmsetup info -c -o name,major,minor,open,attr
```

Filter for one VG:

```bash
dmsetup info -c -o name,major,minor,open,attr |
grep "$VG"
```

### Show block-device hierarchy

```bash
lsblk -o NAME,KNAME,MAJ:MIN,TYPE,FSTYPE,SIZE,MOUNTPOINTS,PKNAME
```

For one disk:

```bash
lsblk -o NAME,KNAME,MAJ:MIN,TYPE,FSTYPE,SIZE,MOUNTPOINTS,PKNAME "$DEV"
```

---

## 5. Interpret dm-thin Status

Example thin-LV status:

```text
0 4612096 thin 4612096 4612095
```

Important fields:

```text
<start> <length> thin <mapped sectors> <highest mapped sector>
```

In this example:

```text
Total sectors:          4,612,096
Mapped sectors:         4,612,096
Highest mapped sector:  4,612,095
```

The thin LV is fully mapped.

Example thin-pool table:

```text
thin-pool 254:0 254:1 2048 0 0
```

The chunk size is expressed in 512-byte sectors:

```text
2048 × 512 bytes = 1 MiB
```

Calculate the number of chunks in a thin LV:

```bash
TOTAL_SECTORS=4612096
CHUNK_SECTORS=2048

echo $((TOTAL_SECTORS / CHUNK_SECTORS))
```

---

## 6. Find Mounts and Device Users

### Find mounted filesystems

```bash
findmnt
```

Search for a device, VG, or mapper name:

```bash
findmnt -rn -o TARGET,SOURCE |
grep -E 'nvme0n1|vg1|dm-' || true
```

Check a specific target:

```bash
findmnt -M /path/to/mountpoint
```

### Check which processes use a block device

```bash
fuser -v "$DEV" 2>/dev/null || true
lsof "$DEV" 2>/dev/null || true
```

For an LV:

```bash
fuser -v "/dev/$VG/<lv-name>" 2>/dev/null || true
lsof "/dev/$VG/<lv-name>" 2>/dev/null || true
```

Avoid relying on `fuser -m` for raw block devices because it can produce misleading kernel-related output.

### Check sysfs holders

```bash
ls -la "/sys/class/block/$(basename "$DEV")/holders"
```

List holder names:

```bash
for h in /sys/class/block/"$(basename "$DEV")"/holders/*; do
    [ -e "$h" ] && basename "$h"
done
```

An empty `holders` directory means no upper block device currently claims the disk.

---

## 7. Deactivate LVM Normally

Deactivate one LV:

```bash
lvchange -an "$VG/<lv-name>"
```

Deactivate the entire VG:

```bash
vgchange -an "$VG"
```

Activate the VG:

```bash
vgchange -ay "$VG"
```

If deactivation reports that an LV is in use, inspect:

```bash
dmsetup ls --tree
dmsetup info -c -o name,open,attr
findmnt
fuser -v "/dev/$VG/<lv-name>"
```

---

## 8. Remove Stale Device-Mapper Mappings

Only do this after all VMs, pods, mounts, and users of the devices have been stopped.

Use the exact mapping names from:

```bash
dmsetup ls --tree
```

Remove the top-level thin LV first:

```bash
dmsetup remove --retry <thin-lv-mapping>
```

Then remove the pool mappings from top to bottom:

```bash
dmsetup remove --retry <thinpool-mapping>
dmsetup remove --retry <thinpool-tpool-mapping>
dmsetup remove --retry <thinpool-tdata-mapping>
dmsetup remove --retry <thinpool-tmeta-mapping>
```

Example naming pattern:

```text
vg1-pvc--UUID
vg1-vg1--thinpool
vg1-vg1--thinpool-tpool
vg1-vg1--thinpool_tdata
vg1-vg1--thinpool_tmeta
```

Deferred removal:

```bash
dmsetup remove --deferred <mapping-name>
```

`--deferred` schedules removal after the last opener releases the device. It does not make the underlying disk immediately available.

### Cleanest option after intentionally corrupting LVM

```bash
sync
reboot
```

A reboot clears stale in-kernel device-mapper mappings when the on-disk VG metadata is already gone.

---

## 9. Inspect Disk Signatures

Non-destructive inspection:

```bash
wipefs "$DEV"
blkid -p "$DEV" || true
```

Show block-device metadata:

```bash
lsblk -f "$DEV"
```

Check the first sectors:

```bash
dd if="$DEV" bs=512 count=8 status=none |
strings
```

For an LVM PV, expected strings include:

```text
LABELONE
LVM2 001
```

---

## 10. Inspect the LVM PV Header and VG Metadata

### Dump the PV and metadata-area headers

```bash
pvck --dump headers "$DEV"
```

Healthy PV output should include:

```text
label_header.id LABELONE
label_header.sector 1
label_header.type LVM2 001
pv_header.pv_uuid ...
```

### Dump all VG metadata found on the PV

```bash
pvck --dump metadata_all "$DEV"
```

Healthy VG metadata should include:

```text
vg vg1
seqno ...
id ...
```

### Damaged or missing PV example

```text
label_header.id ????????
CHECK: label_header.id expected LABELONE
pv_header.pv_uuid invalid format
zero metadata copies
```

This means the PV label and VG metadata are not present on the disk.

---

## 11. Check Automatic LVM Metadata Backups

LVM usually writes VG backups under:

```bash
ls -l /etc/lvm/backup/
ls -lt /etc/lvm/archive/ | head
```

Inspect a VG backup:

```bash
sed -n '1,200p' "/etc/lvm/backup/$VG"
```

Useful fields include:

```text
id
seqno
physical_volumes
device
```

---

## 12. Debug Why LVM Does Not Discover a Device

### Check whether the LVM devices file is enabled

```bash
lvmdevices
lvmconfig --type current devices/use_devicesfile
```

Check device-file configuration:

```bash
lvmconfig --type current devices/devicesfile
ls -l /etc/lvm/devices/ 2>/dev/null
cat /etc/lvm/devices/system.devices 2>/dev/null
```

### Check LVM filters

```bash
lvmconfig --type current |
grep -E 'use_devicesfile|devicesfile|filter|global_filter'
```

Full device configuration:

```bash
lvmconfig --type full devices |
sed -n '1,260p'
```

### Explicit scan of one device

```bash
pvs --devices "$DEV" \
  -o pv_name,pv_uuid,vg_name,pv_size,pv_free

vgs --devices "$DEV" \
  -o vg_name,vg_uuid,vg_size,vg_free
```

### Bypass the hints file

```bash
pvs --nohints
vgs --nohints
```

Refresh the cache:

```bash
pvscan --cache --nohints "$DEV"
vgscan --cache --nohints
```

### Very verbose scan

```bash
pvs \
  --nohints \
  --foreign \
  --devices "$DEV" \
  -vvvv 2>&1 |
tee /tmp/pvs-debug.log
```

Search for rejection reasons:

```bash
grep -Ei \
  'nvme|filter|skip|reject|excluded|duplicate|system.?id|signature|device type' \
  /tmp/pvs-debug.log
```

---

## 13. Wipe and Recreate a PV and VG

This destroys existing storage metadata on the target disk.

### Confirm the device identity first

```bash
lsblk -ndo NAME,MAJ:MIN,SERIAL,MODEL,SIZE "$DEV"

udevadm info --query=property --name="$DEV" |
grep -E 'DEVNAME|DEVPATH|ID_SERIAL|ID_MODEL'
```

### Check for holders and mounts

```bash
ls -la "/sys/class/block/$(basename "$DEV")/holders"
findmnt -rn -o TARGET,SOURCE |
grep -E "$(basename "$DEV")|$VG|dm-" || true
fuser -v "$DEV" 2>/dev/null || true
```

### Remove signatures

```bash
wipefs -a -f "$DEV"
```

Verify that no known signatures remain:

```bash
wipefs "$DEV"
blkid -p "$DEV" || true
```

### For a disposable SSD, discard the whole device

```bash
blkdiscard "$DEV"
```

Do not add `-f` while stale device-mapper mappings or active users may still exist.

### Create the PV

```bash
pvcreate -ff -y "$DEV"
```

Immediately verify the header:

```bash
pvck --dump headers "$DEV"
pvs
```

### Create the VG

```bash
vgcreate "$VG" "$DEV"
```

Verify metadata:

```bash
pvck --dump metadata_all "$DEV"
pvs
vgs
```

### Create a thin pool

Example using 90% of the VG:

```bash
lvcreate \
  --type thin-pool \
  --name "$THINPOOL" \
  --extents 90%VG \
  "$VG"
```

Verify:

```bash
lvs -a \
  -o lv_name,vg_name,lv_attr,lv_size,pool_lv,data_percent,metadata_percent
```

---

## 14. Detect Metadata That Disappears After Creation

Create the PV and inspect it immediately:

```bash
wipefs -a -f "$DEV"
pvcreate -ff -y "$DEV"
pvck --dump headers "$DEV"
```

Check repeatedly:

```bash
for delay in 1 2 5 10; do
    sleep "$delay"
    echo "=== after ${delay}s ==="

    pvck --dump headers "$DEV" 2>&1 |
    grep -E \
      'label_header.id|label_header.type|pv_header.pv_uuid|zero metadata'
done
```

Create the VG and inspect again:

```bash
vgcreate "$VG" "$DEV"
pvck --dump metadata_all "$DEV"
pvs
vgs
```

If the header initially contains `LABELONE` but later turns into zeros, another process is overwriting the disk.

### Search for destructive commands

```bash
ps -efww |
grep -E \
  '[d]d .*nvme|[b]lkdiscard .*nvme|[w]ipefs .*nvme|[p]vremove|[v]gremove|[p]vcreate|[v]gcreate'
```

Check shell history:

```bash
history |
grep -E 'nvme|dd |blkdiscard|wipefs|pvremove|vgremove'
```

### Check kernel and NVMe errors

```bash
dmesg -T |
grep -Ei 'nvme|reset|I/O error|read-only|critical warning' |
tail -100
```

### Audit writes to the disk

When `auditctl` is available:

```bash
auditctl -w "$DEV" -p wa -k lvm-disk-write
```

Reproduce the issue, then inspect:

```bash
ausearch -k lvm-disk-write -i
```

Remove the audit rule afterward:

```bash
auditctl -W "$DEV" -k lvm-disk-write
```

---

## 15. Test Whether Plain Thin-LV Creation Allocates Space

Create a disposable thin LV:

```bash
lvcreate \
  --virtualsize 2200M \
  --thinpool "$VG/$THINPOOL" \
  --name thin-test \
  "$VG"
```

Check its initial usage:

```bash
lvs -o lv_name,lv_size,pool_lv,data_percent "$VG/thin-test"
dmsetup status "${VG}-thin--test"
```

An untouched thin LV should normally start near:

```text
Data% 0.00
```

Remove it:

```bash
lvremove -y "$VG/thin-test"
```

If a CSI-created LV changes from near `0%` to `100%`, a higher layer likely wrote across the device, such as:

- CDI import
- clone
- restore
- image conversion
- full-device zeroing
- VM guest writes

---

## 16. Map an LVM LV Back to a Kubernetes PVC

CSI-created LVs often use:

```text
pvc-<PVC-UID>
```

Given:

```bash
UID=db0e263a-719c-4ab0-9205-cc00f68d3c7f
```

Find the PVC:

```bash
kubectl get pvc -A -o json |
jq -r --arg uid "$UID" '
  .items[]
  | select(.metadata.uid == $uid)
  | {
      namespace: .metadata.namespace,
      name: .metadata.name,
      phase: .status.phase,
      storageClass: .spec.storageClassName,
      selectedNode:
        .metadata.annotations["volume.kubernetes.io/selected-node"],
      owners: .metadata.ownerReferences
    }
'
```

Inspect it:

```bash
kubectl describe pvc <pvc-name> -n <namespace>
kubectl get pvc <pvc-name> -n <namespace> -o yaml
```

Show owner references:

```bash
kubectl get pvc <pvc-name> -n <namespace> \
  -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}{"/"}{.name}{"\n"}{end}'
```

---

## 17. Useful One-Shot Diagnostic Bundle

```bash
DEV=/dev/nvme0n1
VG=vg1

echo '=== lsblk ==='
lsblk -o NAME,KNAME,MAJ:MIN,TYPE,FSTYPE,SIZE,MOUNTPOINTS,PKNAME "$DEV"

echo
echo '=== LVM ==='
pvs -o pv_name,pv_uuid,vg_name,pv_size,pv_free,pv_attr
vgs -o vg_name,vg_uuid,vg_attr,vg_size,vg_free,pv_count,lv_count
lvs -a \
  -o lv_name,vg_name,lv_attr,lv_size,pool_lv,origin,data_percent,metadata_percent,devices

echo
echo '=== device mapper tree ==='
dmsetup ls --tree

echo
echo '=== device mapper status ==='
dmsetup status

echo
echo '=== open counts ==='
dmsetup info -c -o name,major,minor,open,attr

echo
echo '=== holders ==='
ls -la "/sys/class/block/$(basename "$DEV")/holders"

echo
echo '=== mounts ==='
findmnt -rn -o TARGET,SOURCE |
grep -E "$(basename "$DEV")|$VG|dm-" || true

echo
echo '=== signatures ==='
wipefs "$DEV"
blkid -p "$DEV" || true

echo
echo '=== PV headers ==='
pvck --dump headers "$DEV"

echo
echo '=== VG metadata ==='
pvck --dump metadata_all "$DEV"
```

---

## 18. Recovery Decision Guide

### `pvs` is empty and `pvck` shows `LABELONE`

The PV exists, but discovery is filtering or skipping it.

Check:

```bash
lvmconfig --type current |
grep -E 'use_devicesfile|devicesfile|filter|global_filter'

pvs --nohints --foreign --devices "$DEV" -vvvv
```

### `pvs` is empty and `pvck` shows zeros

The PV metadata is absent.

For a disposable disk:

```bash
wipefs -a -f "$DEV"
pvcreate -ff -y "$DEV"
vgcreate "$VG" "$DEV"
```

### `pvcreate` says it cannot open the device exclusively

The device is still mounted or held by device mapper.

Check:

```bash
findmnt
dmsetup ls --tree
dmsetup info -c -o name,open,attr
ls -la "/sys/class/block/$(basename "$DEV")/holders"
fuser -v "$DEV"
```

For an intentionally corrupted test environment, the cleanest fix is often:

```bash
sync
reboot
```

Then:

```bash
wipefs -a -f "$DEV"
pvcreate -ff -y "$DEV"
vgcreate "$VG" "$DEV"
```

### Thin LV is `Data%=100`, but pool usage is low

The LV's full virtual address range has mapped chunks, but it occupies only a small fraction of the overall pool.

Confirm:

```bash
dmsetup status <thin-lv-mapping>
dmsetup status <thinpool-tpool-mapping>
```

Calculate chunk count using the pool chunk size from:

```bash
dmsetup table <thinpool-tpool-mapping>
```

---

## 19. Recover a Thin Pool That Fails to Activate

This section covers a failure sequence like:

```text
Activation of logical volume vg1/vg1-thinpool is prohibited while
logical volume vg1/vg1-thinpool_tdata is active.
```

followed by a targeted activation failure:

```text
Check of pool vg1/vg1-thinpool failed (status:64).
Manual repair required!
```

The first message alone can indicate a standalone `_tdata`/`_tmeta` mapping,
an active consumer, or competing activation attempts. The second message means
LVM's thin metadata check failed and intentionally prevented pool activation.
Do not bypass `thin_check` or force device-mapper activation.

### Quiesce storage operations

Before changing anything:

- stop VMs and pods using LVs from the pool;
- stop new PVC provisioning, clone, snapshot, restore, expansion, and deletion
  operations on the node; and
- confirm no process is still writing to a pool-backed LV.

Record the current state:

```bash
lvs -a \
  -o vg_name,lv_name,lv_size,lv_attr,lv_active,segtype,pool_lv,origin,devices \
  "$VG"

dmsetup ls --tree
dmsetup info -c --noheadings -o name,open,uuid
findmnt -rn -o TARGET,SOURCE
```

Interpret the result carefully:

- If `_tdata` or `_tmeta` has a nonzero open count, find and stop the consumer.
- If the component is active independently with open count zero, deactivate only
  that exact component before trying normal pool activation.
- If `Active` is blank for every LV and `dmsetup ls` reports no devices, there
  is nothing to deactivate. Continue with a targeted activation attempt.

Example component deactivation, only after confirming zero users:

```bash
lvchange -an "$VG/${THINPOOL}_tdata"
lvchange -an "$VG/${THINPOOL}_tmeta"
```

Do not use `dmsetup remove --force` for this recovery.

### Attempt targeted pool activation

```bash
lvchange -ay "$VG/$THINPOOL"
activation_status=$?
echo "activation exit code: $activation_status"
```

If this succeeds, inspect the dependency tree and then activate the remaining
LVs normally:

```bash
dmsetup ls --tree
vgchange -ay "$VG"
```

If activation reports `Check of pool ... failed` and `Manual repair required`,
leave the pool inactive and proceed to metadata repair.

### Save the LVM layout before repair

```bash
recovery_dir="/home/rancher/lvm-recovery"
mkdir -p "$recovery_dir"

vgcfgbackup \
  -f "$recovery_dir/${VG}-before-thin-repair.vgcfg" \
  "$VG"

vgs -o vg_name,vg_size,vg_free,pv_count,lv_count "$VG"
lvs -a \
  -o vg_name,lv_name,lv_size,lv_attr,segtype,pool_lv,origin,devices \
  "$VG"
```

`vgcfgbackup` records the VG layout, but it does **not** back up dm-thin mapping
metadata. Preserve any metadata LV produced by the repair until data recovery
has been verified.

Confirm that the VG has a pool metadata spare:

```bash
lvs -a -o vg_name,lv_name,lv_size,lv_attr "$VG" |
grep '_pmspare'
```

It commonly appears as:

```text
[lvol0_pmspare]
```

or:

```text
[lvol1_pmspare]
```

### Repair the thin-pool metadata

Run the supported LVM repair interactively and retain its complete output:

```bash
lvconvert --repair "$VG/$THINPOOL"
```

Do not add `--force`. During a successful repair, LVM:

1. runs `thin_repair` against the damaged metadata;
2. writes repaired metadata to the VG's `_pmspare` LV;
3. swaps the repaired metadata into the thin pool; and
4. exposes the old unrepaired metadata as `${THINPOOL}_meta0`, or another
   `${THINPOOL}_metaN` name.

Example successful-repair warning:

```text
LV vg1/vg1-thinpool_meta0 holds a backup of the unrepaired metadata.
Use lvremove when no longer required.
```

Do not remove that backup yet. If `lvconvert --repair` fails, stop and preserve
the original metadata for support or advanced recovery. Do not repeatedly run
repair with stronger force options.

### Activate and verify the repaired pool

```bash
lvs -a \
  -o vg_name,lv_name,lv_size,lv_attr,lv_active,segtype,pool_lv,origin \
  "$VG"

lvchange -ay "$VG/$THINPOOL"
vgchange -ay "$VG"

lvs -a \
  -o vg_name,lv_name,lv_attr,lv_active,segtype,pool_lv,data_percent,metadata_percent \
  "$VG"

dmsetup ls --tree
```

A repaired and active pool should have an assembled dependency tree:

```text
vg1-pvc--...
 └─vg1-vg1--thinpool-tpool
    ├─vg1-vg1--thinpool_tdata
    └─vg1-vg1--thinpool_tmeta
```

Validate every important thin LV and its filesystem or VM data. Metadata repair
can discard mappings that cannot be reconstructed. Keep `${THINPOOL}_metaN`
until recovery and data-integrity checks are complete.

Warnings that the sum of thin-LV virtual sizes exceeds the physical pool are
normal for thin provisioning, but pool exhaustion still needs protection.
Configure monitoring and automatic extension, and keep free VG extents
available:

```bash
lvs -o lv_name,seg_monitor,data_percent,metadata_percent "$VG/$THINPOOL"
lvmconfig --type current activation/thin_pool_autoextend_threshold
lvmconfig --type current activation/thin_pool_autoextend_percent
```

### CSI driver startup implication

A CSI node plugin should not require global `vgchange -ay` to succeed before it
creates its socket. A damaged or unrelated VG would otherwise crash-loop the
whole node service. Prefer starting the plugin first and activating only the
requested VG/LV during the node operation. CSI containers should also use the
same host LVM configuration, udev data, and shared LVM lock directory as helper
pods and host-side LVM commands.

---

## 20. Delete All dm-thin Child LVs From One Thin Pool

This procedure permanently deletes every child thin LV selected from one exact
thin pool, while retaining:

- the thin pool itself;
- its `_tdata` and `_tmeta` component LVs;
- the VG's `_pmspare`; and
- any `${THINPOOL}_metaN` backup created by metadata repair.

Delete the corresponding Harvester VMs, VM backups/restores, VolumeSnapshots,
PVCs, and PVs through Kubernetes first whenever possible. Removing LVs directly
while Kubernetes objects remain creates stale PV/PVC records that still refer
to nonexistent storage.

Check for open mappings before deletion:

```bash
dmsetup info -c --noheadings --separator ' ' -o name,open |
awk -v vg="$VG" '$1 ~ ("^" vg "-") && $2 != 0'
```

Do not continue while this prints any child LV that will be deleted.

Save the following as `delete-thin-pool-children.sh` and run it with Bash:

```bash
#!/usr/bin/env bash

set -Eeuo pipefail

thin_vg="${1:-vg1}"
thin_pool="${2:-vg1-thinpool}"

for required_command in jq lvs lvremove xargs; do
    command -v "$required_command" >/dev/null 2>&1 || {
        echo "Required command not found: $required_command" >&2
        exit 1
    }
done

[[ "$thin_vg" =~ ^[a-zA-Z0-9+_.-]+$ ]] || {
    echo "Invalid VG name: $thin_vg" >&2
    exit 1
}
[[ "$thin_pool" =~ ^[a-zA-Z0-9+_.-]+$ ]] || {
    echo "Invalid thin-pool name: $thin_pool" >&2
    exit 1
}

pool_type="$(
    lvs --noheadings -o segtype "$thin_vg/$thin_pool" 2>/dev/null |
    xargs
)"
[[ "$pool_type" == "thin-pool" ]] || {
    echo "$thin_vg/$thin_pool is not a thin pool" >&2
    exit 1
}

# Select only public thin LVs whose pool_lv is the requested pool. The pool,
# _tdata, _tmeta, _pmspare, and repaired metadata backups do not match.
mapfile -t thin_volume_names < <(
    lvs --reportformat json \
        -o vg_name,lv_name,segtype,pool_lv "$thin_vg" |
    jq -r \
        --arg vg "$thin_vg" \
        --arg pool "$thin_pool" '
          .report[].lv[]
          | select(
              .vg_name == $vg and
              .segtype == "thin" and
              .pool_lv == $pool
            )
          | .lv_name
        '
)

if ((${#thin_volume_names[@]} == 0)); then
    echo "No child thin LVs found in $thin_vg/$thin_pool"
    exit 0
fi

echo "The following ${#thin_volume_names[@]} thin LVs will be permanently deleted:"
for thin_volume_name in "${thin_volume_names[@]}"; do
    printf '  %s/%s\n' "$thin_vg" "$thin_volume_name"
done

confirmation="DELETE ${#thin_volume_names[@]} THIN LVS FROM $thin_vg/$thin_pool"
read -r -p "Type '$confirmation' to continue: " answer
[[ "$answer" == "$confirmation" ]] || {
    echo "Cancelled"
    exit 1
}

for thin_volume_name in "${thin_volume_names[@]}"; do
    # Revalidate the exact type and parent pool immediately before deletion.
    current_type="$(
        lvs --noheadings -o segtype "$thin_vg/$thin_volume_name" |
        xargs
    )"
    current_pool="$(
        lvs --noheadings -o pool_lv "$thin_vg/$thin_volume_name" |
        xargs
    )"

    if [[ "$current_type" != "thin" || "$current_pool" != "$thin_pool" ]]; then
        echo "Refusing unexpected LV: $thin_vg/$thin_volume_name" >&2
        exit 1
    fi

    echo "Deleting $thin_vg/$thin_volume_name"
    # -y answers the confirmation prompt. It is intentionally not --force.
    lvremove -y "$thin_vg/$thin_volume_name"
done

echo "Verifying that no child thin LVs remain in $thin_vg/$thin_pool"
lvs --reportformat json \
    -o vg_name,lv_name,segtype,pool_lv "$thin_vg" |
jq -r \
    --arg vg "$thin_vg" \
    --arg pool "$thin_pool" '
      .report[].lv[]
      | select(
          .vg_name == $vg and
          .segtype == "thin" and
          .pool_lv == $pool
        )
      | [.vg_name, .lv_name, .segtype, .pool_lv]
      | @tsv
    '
```

Run it explicitly against the intended pool:

```bash
chmod +x delete-thin-pool-children.sh
./delete-thin-pool-children.sh vg1 vg1-thinpool
```

The script deliberately avoids `--force`. If an LV remains mounted or open,
`lvremove` should fail and `set -e` stops the deletion loop. Resolve the user and
rerun the script; already deleted LVs will no longer be selected.

Final verification:

```bash
lvs -a \
  -o vg_name,lv_name,lv_attr,lv_size,segtype,pool_lv,data_percent,metadata_percent \
  "$VG"

dmsetup ls --tree
```

Do not automatically delete `${THINPOOL}_metaN`. Keep it until there is no
remaining recovery or support need.
