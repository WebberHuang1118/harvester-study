# Create Loop Devices for Storage Testing on Harvester

This note describes how to create loop devices on Harvester nodes and use them for storage testing. The documented use cases are:

- Longhorn V2 disks
- LVM volume groups

The default Harvester node-disk-manager image may filter out loop devices. For this workflow, use a custom NDM image built from:

https://github.com/WebberHuang1118/node-disk-manager/tree/master-include-loop-dev

References:

- Harvester multi-disk management: https://docs.harvesterhci.io/v1.9/host/#multi-disk-management
- Longhorn V2 Data Engine: https://docs.harvesterhci.io/v1.9/advanced/longhorn-v2/
- Harvester LVM Local Storage: https://docs.harvesterhci.io/v1.9/advanced/addons/lvm-local-storage/

## Assumptions

- Enable the storage feature required by the chosen test: Longhorn V2 Data Engine or LVM Local Storage.
- You have cluster admin access through `kubectl`.
- You can SSH into the Harvester node where the loop device will be created.
- The custom NDM image has been pushed to a registry reachable by the Harvester nodes.
- This is for a quick test environment, not production storage.

## 1. Build and Push the Custom NDM Image

Build the image from the branch that includes loop device discovery:

```bash
git clone -b master-include-loop-dev https://github.com/WebberHuang1118/node-disk-manager.git
cd node-disk-manager
make
```

Tag and push the image to your registry:

```bash
CUSTOM_NDM_IMAGE=<registry>/<repo>/harvester-node-disk-manager:include-loop-dev

docker tag harvester/node-disk-manager:dev "${CUSTOM_NDM_IMAGE}"
docker push "${CUSTOM_NDM_IMAGE}"
```

Replace `<registry>/<repo>/harvester-node-disk-manager:include-loop-dev` with the image name that Harvester nodes can pull.

## 2. Replace the Harvester NDM Image

Record the current image before changing it:

```bash
kubectl -n harvester-system get ds harvester-node-disk-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Patch the DaemonSet to use the custom image:

```bash
CUSTOM_NDM_IMAGE=<registry>/<repo>/harvester-node-disk-manager:include-loop-dev

kubectl -n harvester-system patch ds harvester-node-disk-manager \
  --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${CUSTOM_NDM_IMAGE}\"}]"
```

Wait for the DaemonSet rollout:

```bash
kubectl -n harvester-system rollout status ds/harvester-node-disk-manager
kubectl -n harvester-system get pods -l app=harvester-node-disk-manager -o wide
```

If the pod label differs in your environment, find the pods with:

```bash
kubectl -n harvester-system get pods | grep node-disk-manager
```

## 3. Create a Loop Device on a Harvester Node

SSH into the target Harvester node and create a backing file. Use a size that is an even multiple of 4096 bytes. Values such as `20G`, `50G`, or `100G` are fine for quick testing.

```bash
LOOP_FILE=/var/lib/harvester/defaultdisk/harvester-storage-loop.img
LOOP_SIZE=20G

sudo truncate -s "${LOOP_SIZE}" "${LOOP_FILE}"
sudo losetup --find --show "${LOOP_FILE}"
```

The last command prints the loop device path, for example:

```text
/dev/loop10
```

Store it for the remaining commands:

```bash
LOOP_DEV=/dev/loop10
```

Wipe old signatures if the file/device was reused:

```bash
sudo wipefs -a "${LOOP_DEV}"
```

Loop devices do not have a hardware WWN. The custom NDM image uses the loop backing-file path as a synthetic serial number, so each loop device must use a unique backing file.

Prepare the device according to its intended use.

### 3.1 Longhorn V2 preparation

For Longhorn V2 testing, an ext4 filesystem UUID can help older Harvester versions recognize a device without a WWN. The custom NDM branch described in this guide can instead identify the loop by its backing file, but retaining this step is useful when testing compatibility with older behavior:

```bash
sudo mkfs.ext4 -F "${LOOP_DEV}"
sudo udevadm settle
```

### 3.2 LVM preparation

For LVM, leave the device unformatted. NDM wipes existing signatures before asking the LVMVolumeGroup controller to create the PV and VG:

```bash
sudo wipefs -a "${LOOP_DEV}"
sudo udevadm settle
```

An empty result from `blkid` is expected:

```bash
sudo blkid "${LOOP_DEV}" || true
```

To create two disposable loops for one LVM volume group, use separate backing files:

```bash
LOOP_SIZE=150G

sudo truncate -s "${LOOP_SIZE}" /var/lib/harvester/defaultdisk/lvm1.img
sudo truncate -s "${LOOP_SIZE}" /var/lib/harvester/defaultdisklvm2.img

sudo losetup --find --show /var/lib/harvester/defaultdisk/lvm1.img
sudo losetup --find --show /var/lib/harvester/defaultdisk/lvm2.img
```

Record the paths printed by `losetup`; the examples in the LVM section assume they are `/dev/loop1` and `/dev/loop2`.

Verify the device:

```bash
losetup -a
lsblk -f "${LOOP_DEV}"
blkid "${LOOP_DEV}" || true
```

Example:

```text
/dev/loop10: [2065]:123456 (/var/lib/harvester-storage-loop.img)
```

## 4. Confirm NDM Discovers the Loop Device

From your management machine:

```bash
kubectl get blockdevices.harvesterhci.io -A -o wide
```

Look for a block device on the target node that maps to the loop device. If it does not appear immediately, wait for the NDM rescan interval or restart the NDM pod on that node:

```bash
kubectl -n harvester-system delete pod <node-disk-manager-pod-on-target-node>
kubectl -n harvester-system rollout status ds/harvester-node-disk-manager
```

Then check again:

```bash
kubectl get blockdevices.harvesterhci.io -A -o wide
```

## 5. Add the Loop Device as a Longhorn V2 Disk

In the Harvester UI:

1. Go to **Hosts**.
2. Find the target node.
3. Select the node action menu, then select **Edit Config**.
4. Open the **Storage** tab.
5. Click **Add Disk**.
6. Select the loop device.
7. Set **Provisioner** to **LonghornV2 (CSI)**.
8. Add disk tags if needed.
9. Click **Save**.

After saving, open the host details page and confirm that the disk was added with the Longhorn V2 provisioner.

You can also check from Longhorn:

1. Open the Longhorn UI.
2. Go to **Node**.
3. Select the target node.
4. Confirm the new disk exists and is schedulable.

## 6. Use Loop Devices with LVM

Harvester's host LVM configuration rejects loop devices by default. NDM can discover a loop device while `pvs`, `pvcreate`, and `vgcreate` still reject it, because NDM executes the LVM commands in the host namespaces and therefore uses the host's LVM configuration.

### 6.1 Confirm the active LVM device policy

On the Harvester node, run:

```bash
pvs --all -o pv_name,vg_name
vgs

lvmconfig --type current \
  devices/filter \
  devices/global_filter \
  devices/use_devicesfile

lvmdevices 2>/dev/null || true
```

A configuration such as the following prevents LVM from using any loop device:

```text
global_filter=["r|/dev/loop.*|","r|/dev/disk/by-path/.*longhorn.*|","r|/dev/mapper/pvc-.*|"]
use_devicesfile=0
```

When `use_devicesfile=0`, the LVM devices file and `lvmdevices` are not the blocker. The `global_filter` is the relevant setting.

### 6.2 Test a narrow loop-device allowlist

LVM uses the first matching filter rule. Add exact accept rules for the test loop devices before the general loop-device rejection. Do not remove the Longhorn-related rejection rules.

The following example permits only `/dev/loop1` and `/dev/loop2` while continuing to reject all other loop devices:

```bash
sudo pvs --config 'devices {
  global_filter=[
    "a|^/dev/loop1$|",
    "a|^/dev/loop2$|",
    "r|^/dev/loop.*|",
    "r|/dev/disk/by-path/.*longhorn.*|",
    "r|/dev/mapper/pvc-.*|"
  ]
}' --all -o pv_name,vg_name
```

Replace `/dev/loop1` and `/dev/loop2` with the current paths reported by `losetup -a`. A non-writing `pvcreate` test can confirm that LVM accepts a device:

```bash
sudo pvcreate --test --config 'devices {
  global_filter=[
    "a|^/dev/loop1$|",
    "a|^/dev/loop2$|",
    "r|^/dev/loop.*|",
    "r|/dev/disk/by-path/.*longhorn.*|",
    "r|/dev/mapper/pvc-.*|"
  ]
}' /dev/loop1
```

`--test` does not write PV metadata. Do not run `pvcreate` or `vgcreate` without `--test`; NDM owns the PV and VG lifecycle after the disk is selected in Harvester.

### 6.3 Make the filter change persistent

Locate the configuration file that supplies the active setting:

```bash
sudo grep -Rns --include='*.conf' 'global_filter' /etc/lvm
```

Back up that file, then edit its existing `devices/global_filter` value. The resulting value should preserve the existing rejection rules and place the exact loop-device accept rules first:

```conf
devices {
    global_filter = [
        "a|^/dev/loop1$|",
        "a|^/dev/loop2$|",
        "r|^/dev/loop.*|",
        "r|/dev/disk/by-path/.*longhorn.*|",
        "r|/dev/mapper/pvc-.*|"
    ]
}
```

For example, if the setting is in `/etc/lvm/lvm.conf`:

```bash
sudo cp -a /etc/lvm/lvm.conf /etc/lvm/lvm.conf.before-loop-test
sudo vi /etc/lvm/lvm.conf
```

Validate the effective configuration and refresh LVM's scan cache:

```bash
lvmconfig --type current devices/global_filter devices/use_devicesfile
sudo vgscan --cache
pvs --all -o pv_name,vg_name
```

Harvester uses an immutable operating system. Confirm that the chosen configuration mechanism survives a reboot if the loop-device test must be persistent. The loop devices themselves must also be reattached after reboot, and `/dev/loopN` numbers can change. Update the exact allow rules when those numbers change.

### 6.4 Add the loop devices to an LVM volume group

In the Harvester UI:

1. Go to **Hosts**.
2. Find the target node.
3. Select the node action menu, then select **Edit Config**.
4. Open the **Storage** tab.
5. Add each loop device.
6. Set **Provisioner** to **LVM**.
7. Set the same volume group name, for example `vg1`, for both devices.
8. Click **Save**.

NDM creates an `LVMVolumeGroup` resource in `harvester-system`. The BlockDevices remain `Unprovisioned` until this resource reports `status.vgStatus: Active`.

Verify the resources:

```bash
kubectl -n harvester-system get \
  lvmvolumegroups.harvesterhci.io -o yaml

kubectl get blockdevices.harvesterhci.io -A -o wide
```

Verify the host LVM state:

```bash
sudo pvs -o pv_name,vg_name,pv_size,pv_free
sudo vgs -o vg_name,vg_size,vg_free,pv_count
```

Expected state:

- Both loop devices appear as PVs in the requested VG.
- The `LVMVolumeGroup` reports `Active`.
- Both BlockDevices report `Provisioned`.

If the `LVMVolumeGroup` status remains empty, inspect the NDM pod on that node:

```bash
kubectl -n harvester-system get pods -o wide | grep node-disk-manager

kubectl -n harvester-system logs <node-disk-manager-pod> --since=1h |
grep -Ei 'error syncing|LVMVolumeGroup|vgcreate|pvcreate|excluded|devices file|vg1'
```

If the filter accepts the loops but the log shows `pvcreate` being attempted immediately after `vgcreate`, the failure is in the NDM VG creation flow: `vgcreate` already initializes its first device as a PV. Fix that controller flow instead of manually creating competing PV/VG state.

## 7. Validate Longhorn V2

Create a test VM or volume that uses a Longhorn V2 StorageClass and, if you used disk tags, make sure the StorageClass selects the same disk tag.

Watch Longhorn replicas:

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o wide
```

Check the node and disk state:

```bash
kubectl -n longhorn-system get nodes.longhorn.io -o yaml
```

## 8. Remove a Longhorn V2 Loop Device Safely

To remove the loop device safely, remove the Longhorn V2 sources first, stop Longhorn scheduling on the disk, remove the disk from the Harvester host, then detach it from Linux.

### 8.1 Remove V2 consumers and sources

Before removing the loop disk, delete or move anything that may still reference it.

In the Harvester UI, remove VMs, volumes, and VM images that were created for this V2 loop-disk test. Check at least:

- **Virtual Machines**
- **Volumes**
- **Images**

For VM images, remove any image that was imported using the Longhorn V2 StorageClass or that created backing image/volume data on the loop disk.

From Kubernetes, you can also inspect common Harvester and Longhorn resources:

```bash
kubectl get volumes -A
kubectl get virtualmachineimages.harvesterhci.io -A
kubectl -n longhorn-system get volumes.longhorn.io -o wide
kubectl -n longhorn-system get backingimages.longhorn.io -o wide
kubectl -n longhorn-system get replicas.longhorn.io -o wide
```

Proceed only after the test volumes, VM images, backing images, and replicas that use the loop disk are removed or rebuilt somewhere else.

### 8.2 Disable scheduling and confirm Longhorn is clear

In the Longhorn UI, go to:

```text
Longhorn UI -> Node -> select the node -> Disks
```

For the loop disk, first set:

```text
Allow Scheduling: false
```

Then make sure no replicas, volumes, or backing images are using it.

If Longhorn still shows data on the disk, do not continue. Remove or move the remaining volume, VM image, backing image, or replica data first.

### 8.3 Remove the disk from the Harvester host

In the Harvester UI:

1. Go to **Hosts**.
2. Find the target node.
3. Select the node action menu, then select **Edit Config**.
4. Open the **Storage** tab.
5. Remove the loop disk from the disk list.
6. Click **Save**.

If Harvester refuses to remove the disk, some Longhorn V2 data still exists on the disk. Go back to the previous step and remove or move the remaining volume, VM image, backing image, or replica data first.

### 8.4 Check which loop device was used

On the Harvester node:

```bash
losetup -a
```

Example:

```text
/dev/loop10: [2065]:123456 (/var/lib/harvester-storage-loop.img)
```

### 8.5 Detach the loop device

```bash
sudo losetup -d /dev/loop10
```

Then verify:

```bash
losetup -a
lsblk
```

### 8.6 Remove the backing file

Only do this after the loop device is detached and Longhorn no longer uses it:

```bash
sudo rm -f /var/lib/harvester-storage-loop.img
```

## 9. Remove an LVM Loop Device Safely

Remove all LVM Local Storage volumes that use the VG before removing its loop devices. Confirm that no logical volumes remain:

```bash
sudo lvs -a -o lv_name,vg_name,lv_size,devices
```

Remove each loop disk from the Harvester host's **Storage** configuration and wait for its BlockDevice to return to `Unprovisioned`. NDM should remove the PV from the VG, or remove the VG when its last PV is removed.

Verify that LVM no longer owns the device before detaching it:

```bash
sudo pvs -o pv_name,vg_name
sudo vgs
sudo wipefs /dev/loop1
```

Only after the target loop device is absent from `pvs`, detach it and remove its backing file:

```bash
sudo losetup -d /dev/loop1
sudo rm -f /var/lib/lvm1.img
```

When the LVM loop test is finished, restore the original `global_filter`, validate it with `lvmconfig`, and run `vgscan --cache` again.

## 10. If `losetup -d` Says the Device Is Busy

Check who is using it:

```bash
lsblk /dev/loop10
sudo lsof /dev/loop10
sudo fuser -v /dev/loop10
```

Also check whether Longhorn, SPDK, LVM, or device mapper still has it open:

```bash
sudo pvs -o pv_name,vg_name
sudo lvs -a -o lv_name,vg_name,devices
sudo dmsetup ls --tree
```

For Longhorn V2, remove the V2 consumers and sources first, remove the disk from the Harvester host, and confirm Longhorn no longer owns the disk. If the disk has already been removed from Harvester and Longhorn but remains busy, restart the related Longhorn instance-manager on the node and check again.

For LVM, do not detach the device while it is still listed by `pvs` or referenced by `lvs`/`dmsetup`. Remove its consumers and unprovision it through Harvester first.

For a quick test environment, the safest order is:

```bash
# 1. Remove test VMs, volumes, VM images, backing images, and replicas first.

# 2. Disable scheduling for the disk in Longhorn and confirm it has no data.

# 3. Remove the loop disk from the Harvester host:
#    Hosts -> target node -> Edit Config -> Storage -> remove disk -> Save.

# 4. Confirm the loop device.
losetup -a

# 5. Detach the loop device.
sudo losetup -d /dev/loop10

# 6. Delete the backing file.
sudo rm -f /var/lib/harvester-storage-loop.img
```

## 11. Roll Back the NDM Image

After testing, restore the original NDM image that you recorded earlier:

```bash
ORIGINAL_NDM_IMAGE=<original-image>

kubectl -n harvester-system patch ds harvester-node-disk-manager \
  --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${ORIGINAL_NDM_IMAGE}\"}]"

kubectl -n harvester-system rollout status ds/harvester-node-disk-manager
```

## Notes

- Loop devices are ephemeral unless you recreate them after reboot.
- This workflow is intended for Longhorn V2 and LVM test coverage when real spare disks are not available.
- Do not delete the backing file while the loop device is still attached.
- Do not detach the loop device before removing its Longhorn V2 or LVM consumers and removing the disk from the Harvester host.
- If the loop device is reused, wipe old filesystem signatures before creating a new filesystem UUID.
