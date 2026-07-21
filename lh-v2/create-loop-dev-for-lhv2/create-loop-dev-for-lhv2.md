# Create Loop Devices for Longhorn V2 Testing on Harvester

This note describes how to create a loop device on Harvester nodes and use it as a Longhorn V2 disk for test environments.

The default Harvester node-disk-manager image may filter out loop devices. For this workflow, use a custom NDM image built from:

https://github.com/WebberHuang1118/node-disk-manager/tree/master-include-loop-dev

References:

- Harvester multi-disk management: https://docs.harvesterhci.io/v1.9/host/#multi-disk-management
- Longhorn V2 Data Engine: https://docs.harvesterhci.io/v1.9/advanced/longhorn-v2/

## Assumptions

- Longhorn V2 Data Engine is enabled in Harvester.
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

## 3. Create the Loop Device on a Harvester Node

SSH into the target Harvester node and create a backing file. Use a size that is an even multiple of 4096 bytes. Values such as `20G`, `50G`, or `100G` are fine for quick testing.

```bash
LOOP_FILE=/var/lib/longhorn-v2-loop.img
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

Loop devices do not have a real hardware WWN. Harvester requires each disk to have a unique identifier; the Harvester docs note that formatting a disk with `EXT4` can help Harvester recognize disks without WWN. For this test loop device, create an ext4 filesystem so NDM can use the filesystem UUID during discovery:

```bash
sudo mkfs.ext4 -F "${LOOP_DEV}"
sudo udevadm settle
```

Verify the device:

```bash
losetup -a
lsblk -f "${LOOP_DEV}"
blkid "${LOOP_DEV}"
```

Example:

```text
/dev/loop10: [2065]:123456 (/var/lib/longhorn-v2-loop.img)
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

## 6. Quick Validation

Create a test VM or volume that uses a Longhorn V2 StorageClass and, if you used disk tags, make sure the StorageClass selects the same disk tag.

Watch Longhorn replicas:

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o wide
```

Check the node and disk state:

```bash
kubectl -n longhorn-system get nodes.longhorn.io -o yaml
```

## 7. Remove the Loop Device Safely

To remove the loop device safely, remove the Longhorn V2 sources first, stop Longhorn scheduling on the disk, remove the disk from the Harvester host, then detach it from Linux.

### 7.1 Remove V2 consumers and sources

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

### 7.2 Disable scheduling and confirm Longhorn is clear

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

### 7.3 Remove the disk from the Harvester host

In the Harvester UI:

1. Go to **Hosts**.
2. Find the target node.
3. Select the node action menu, then select **Edit Config**.
4. Open the **Storage** tab.
5. Remove the loop disk from the disk list.
6. Click **Save**.

If Harvester refuses to remove the disk, some Longhorn V2 data still exists on the disk. Go back to the previous step and remove or move the remaining volume, VM image, backing image, or replica data first.

### 7.4 Check which loop device was used

On the Harvester node:

```bash
losetup -a
```

Example:

```text
/dev/loop10: [2065]:123456 (/var/lib/longhorn-v2-loop.img)
```

### 7.5 Detach the loop device

```bash
sudo losetup -d /dev/loop10
```

Then verify:

```bash
losetup -a
lsblk
```

### 7.6 Remove the backing file

Only do this after the loop device is detached and Longhorn no longer uses it:

```bash
sudo rm -f /var/lib/longhorn-v2-loop.img
```

## 8. If `losetup -d` Says the Device Is Busy

Check who is using it:

```bash
lsblk /dev/loop10
sudo lsof /dev/loop10
sudo fuser -v /dev/loop10
```

Also check whether Longhorn or SPDK still has it open. If it was added to Longhorn V2, remove the V2 consumers and sources first, remove the disk from the Harvester host, and confirm Longhorn no longer owns the disk. If the disk has already been removed from Harvester and Longhorn but the device is still busy, restart the related Longhorn instance-manager on the node and check again.

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
sudo rm -f /var/lib/longhorn-v2-loop.img
```

## 9. Roll Back the NDM Image

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
- This workflow is intended for Longhorn V2 test coverage when real spare disks are not available.
- Do not delete the backing file while the loop device is still attached.
- Do not detach the loop device before removing V2 consumers and removing the disk from the Harvester host.
- If the loop device is reused, wipe old filesystem signatures before creating a new filesystem UUID.
