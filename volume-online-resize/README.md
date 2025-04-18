# Volume Online Resize

## Environment
Harvester master commit `dc6013785a4d93f06a58cb0a230fa68fcb78d828` with PR [#7978](https://github.com/harvester/harvester/pull/7978)

## Block Mode PVC (LH)

### Steps
1. Add block mode PVC to VM as hotplug volume:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  namespace: backup
  name: lh-pvc-block
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Block
  resources:
    requests:
      storage: 10Gi
  storageClassName: 1rep
```

2. Before expand (`/dev/sda`):

```bash
$ lsblk
NAME    MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0     7:0    0  63.5M  1 loop /snap/core20/2015
loop1     7:1    0 111.9M  1 loop /snap/lxd/24322
loop2     7:2    0  89.4M  1 loop /snap/lxd/31333
loop3     7:3    0  40.8M  1 loop /snap/snapd/20092
sda       8:0    0    10G  0 disk 
vda     252:0    0     5G  0 disk 
├─vda1  252:1    0   4.9G  0 part /
├─vda14 252:14   0     4M  0 part 
└─vda15 252:15   0   106M  0 part /boot/efi
```

3. After expand (`/dev/sda`):

```bash
$ lsblk
NAME    MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0     7:0    0  63.5M  1 loop /snap/core20/2015
loop1     7:1    0 111.9M  1 loop /snap/lxd/24322
loop2     7:2    0  89.4M  1 loop /snap/lxd/31333
loop3     7:3    0  40.8M  1 loop /snap/snapd/20092
sda       8:0    0   220G  0 disk 
vda     252:0    0     5G  0 disk 
├─vda1  252:1    0   4.9G  0 part /
├─vda14 252:14   0     4M  0 part 
└─vda15 252:15   0   106M  0 part /boot/efi
vdb     252:16   0     1M  0 disk
```

## Filesystem Mode PVC (LH)

### Steps
1. Add filesystem mode PVC to VM as hotplug volume:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  namespace: backup
  name: lh-pvc-fs
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: 10Gi
  storageClassName: 1rep
```

2. Before expand (`/dev/sda`) added as `/dev/vdx` ahead:

```bash
$ lsblk
NAME    MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0     7:0    0  63.5M  1 loop /snap/core20/2015
loop1     7:1    0 111.9M  1 loop /snap/lxd/24322
loop2     7:2    0  89.4M  1 loop /snap/lxd/31333
loop3     7:3    0  40.8M  1 loop /snap/snapd/20092
sda       8:0    0  18.9G  0 disk 
vda     252:0    0     5G  0 disk 
├─vda1  252:1    0   4.9G  0 part /
├─vda14 252:14   0     4M  0 part 
└─vda15 252:15   0   106M  0 part /boot/efi
vdb     252:16   0     1M  0 disk
```

3. After expand (`/dev/sda`):

```bash
$ lsblk
NAME    MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0     7:0    0  63.5M  1 loop /snap/core20/2015
loop1     7:1    0 111.9M  1 loop /snap/lxd/24322
loop2     7:2    0  89.4M  1 loop /snap/lxd/31333
loop3     7:3    0  40.8M  1 loop /snap/snapd/20092
sda       8:0    0  28.3G  0 disk 
vda     252:0    0     5G  0 disk 
├─vda1  252:1    0   4.9G  0 part /
├─vda14 252:14   0     4M  0 part 
└─vda15 252:15   0   106M  0 part /boot/efi
vdb     252:16   0     1M  0 disk
```

### Note
Check the mount point in the hotplug pod to find a disk image file:

```bash
$ ls -al /lh-pvc-fs/
total 28
drwxrwsr-x 3 root qemu        4096 Apr 18 08:36 .
drwxr-xr-x 1 root root        4096 Apr 18 08:36 ..
-rw-r--r-- 1 qemu qemu 30440161280 Apr 18 08:37 disk.img
drwxrws--- 2 root qemu       16384 Apr 18 08:15 lost+found
```