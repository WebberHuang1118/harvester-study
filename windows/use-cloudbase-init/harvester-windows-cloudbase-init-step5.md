# Harvester Windows Cloudbase-Init Step 5 Runbook

This runbook documents how to reproduce the Harvester UI step:

> Create a new Windows virtual machine from the exported Sysprep image and apply a Cloud Configuration Template.

In CLI/Kubernetes terms, Step 5 means:

1. Create cloud-init user-data.
2. Store the user-data in a Kubernetes Secret.
3. Patch the KubeVirt `VirtualMachine` to attach a cloud-init/config-drive disk.
4. Start the VM.
5. Wait for Windows Sysprep/OOBE and Cloudbase-Init to finish.
6. Verify the cloud configuration inside Windows.

Example values used in this runbook:

```text
Namespace: default
VM name: vm-windows-from-export
Cloud Config Template ConfigMap: windows-init
Secret name: windows-init-userdata
```

---

## 1. Example cloud-init user-data

The Cloud Configuration Template content is:

```yaml
#cloud-config
set_hostname: winserver01
set_timezone: America/Sao_Paulo
ntp:
  enabled: true
  servers:
    - a.st1.ntp.br
    - b.st1.ntp.br
write_files:
  - path: C:\status.txt
    content: Initial Configuration Concluded!
    encoding: utf-8
users:
  - name: tux
    password: StrongPassw0rd
    groups:
      - Administrators
runcmd:
  - powershell.exe -Command "Install-WindowsFeature -Name Web-Server -IncludeManagementTools"
  - powershell.exe -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
  - powershell.exe -Command "Start-Service sshd"
  - powershell.exe -Command "Set-Service -Name sshd -StartupType Automatic"
  - powershell.exe -Command "Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0"
  - powershell.exe -Command "Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'"
```

If the cloud configuration succeeds, the simplest verification is:

```cmd
type C:\status.txt
```

Expected output:

```text
Initial Configuration Concluded!
```

---

## 2. Export cloud-init from the Harvester ConfigMap

If the Harvester Cloud Config Template already exists as a ConfigMap:

```yaml
kind: ConfigMap
metadata:
  name: windows-init
  namespace: default
data:
  cloudInit: ...
```

Export it to a local file:

```bash
kubectl get configmap windows-init -n default -o jsonpath='{.data.cloudInit}' > /tmp/windows-userdata.yaml
```

Check the content:

```bash
cat /tmp/windows-userdata.yaml
```

---

## 3. Alternative: create the user-data file manually

If the ConfigMap does not exist, create the file manually:

```bash
cat > /tmp/windows-userdata.yaml <<'EOF'
#cloud-config
set_hostname: winserver01
set_timezone: America/Sao_Paulo
ntp:
  enabled: true
  servers:
    - a.st1.ntp.br
    - b.st1.ntp.br
write_files:
  - path: C:\status.txt
    content: Initial Configuration Concluded!
    encoding: utf-8
users:
  - name: tux
    password: StrongPassw0rd
    groups:
      - Administrators
runcmd:
  - powershell.exe -Command "Install-WindowsFeature -Name Web-Server -IncludeManagementTools"
  - powershell.exe -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
  - powershell.exe -Command "Start-Service sshd"
  - powershell.exe -Command "Set-Service -Name sshd -StartupType Automatic"
  - powershell.exe -Command "Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0"
  - powershell.exe -Command "Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'"
EOF
```

---

## 4. Create a Secret for KubeVirt cloud-init

KubeVirt can consume cloud-init user-data from a Secret. The key should be `userdata`.

Create or update the Secret:

```bash
kubectl create secret generic windows-init-userdata \
  -n default \
  --from-file=userdata=/tmp/windows-userdata.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify:

```bash
kubectl get secret windows-init-userdata -n default
```

Check the Secret YAML:

```bash
kubectl get secret windows-init-userdata -n default -o yaml
```

You should see:

```yaml
data:
  userdata: ...
```

---

## 5. Patch the VM manifest

Your VM initially has only the root disk volume:

```yaml
volumes:
- name: disk-1
  persistentVolumeClaim:
    claimName: vm-windows-from-export-disk-1-tp8cd
```

You need to add a cloud-init disk and a matching cloud-init volume.

Patch the VM with `cloudInitNoCloud`:

```bash
kubectl patch vm vm-windows-from-export -n default --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/domain/devices/disks/-",
    "value": {
      "name": "cloudinitdisk",
      "disk": {
        "bus": "virtio"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "cloudinitdisk",
      "cloudInitNoCloud": {
        "secretRef": {
          "name": "windows-init-userdata"
        }
      }
    }
  }
]'
```

---

## 6. Verify the patch

Check the VM manifest:

```bash
kubectl get vm vm-windows-from-export -n default -o yaml
```

You should see this under `spec.template.spec.domain.devices.disks`:

```yaml
- disk:
    bus: virtio
  name: cloudinitdisk
```

And this under `spec.template.spec.volumes`:

```yaml
- name: cloudinitdisk
  cloudInitNoCloud:
    secretRef:
      name: windows-init-userdata
```

Quick grep check:

```bash
kubectl get vm vm-windows-from-export -n default -o yaml | grep -A20 -B5 cloudinitdisk
```

---

## 7. Alternative: use `cloudInitConfigDrive`

Your Cloudbase-Init configuration includes both metadata services:

```ini
cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService
cloudbaseinit.metadata.services.configdrive.ConfigDriveService
```

The `cloudInitNoCloud` patch usually maps to the NoCloud config-drive path.

If you want to test ConfigDrive explicitly, use `cloudInitConfigDrive` instead:

```bash
kubectl patch vm vm-windows-from-export -n default --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/domain/devices/disks/-",
    "value": {
      "name": "cloudinitdisk",
      "disk": {
        "bus": "virtio"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "cloudinitdisk",
      "cloudInitConfigDrive": {
        "secretRef": {
          "name": "windows-init-userdata"
        }
      }
    }
  }
]'
```

Use either `cloudInitNoCloud` or `cloudInitConfigDrive`, not both for the same `cloudinitdisk`.

---

## 8. Avoid duplicate cloud-init disks

Before patching multiple times, check whether `cloudinitdisk` already exists:

```bash
kubectl get vm vm-windows-from-export -n default -o yaml | grep -A20 -B5 cloudinitdisk
```

If you accidentally added duplicate entries, edit the VM:

```bash
kubectl edit vm vm-windows-from-export -n default
```

Remove duplicates from both:

```yaml
spec.template.spec.domain.devices.disks
spec.template.spec.volumes
```

Keep only one disk named `cloudinitdisk` and one matching volume named `cloudinitdisk`.

---

## 9. Start the VM

If the VM has:

```yaml
spec:
  runStrategy: Halted
```

start it with:

```bash
virtctl start vm-windows-from-export -n default
```

Or patch `runStrategy`:

```bash
kubectl patch vm vm-windows-from-export -n default --type=merge -p '{"spec":{"runStrategy":"RerunOnFailure"}}'
```

Check status:

```bash
kubectl get vm vm-windows-from-export -n default
kubectl get vmi vm-windows-from-export -n default -o wide
```

Watch status:

```bash
watch -n 2 "kubectl get vm,vmi -n default | grep vm-windows-from-export"
```

---

## 10. Expect several Windows reboots

After the new VM boots from the Syspreped image, Windows may reboot several times.

This is expected because Windows is finishing:

```text
Sysprep specialize phase
OOBE phase
Cloudbase-Init unattend phase
Cloudbase-Init normal service phase
Cloud configuration execution
```

Do not assume failure immediately if the VM restarts.

Wait until the VM is stable and reachable through console, RDP, or SSH.

---

## 11. Check the VM IP

From Kubernetes:

```bash
kubectl get vmi vm-windows-from-export -n default -o wide
```

Or:

```bash
kubectl get vmi vm-windows-from-export -n default -o jsonpath='{.status.interfaces[*].ipAddress}{"\n"}'
```

Inside Windows:

```cmd
ipconfig
```

More detail:

```cmd
ipconfig /all
```

PowerShell IPv4 only:

```cmd
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,IPAddress,PrefixLength"
```

---

## 12. Verify Cloudbase-Init success inside Windows

### 12.1 Verify `write_files`

```cmd
type C:\status.txt
```

Expected:

```text
Initial Configuration Concluded!
```

PowerShell version:

```cmd
powershell -NoProfile -Command "Test-Path 'C:\status.txt'; Get-Content 'C:\status.txt'"
```

Expected:

```text
True
Initial Configuration Concluded!
```

### 12.2 Verify hostname

```cmd
hostname
```

Expected:

```text
winserver01
```

PowerShell:

```cmd
powershell -NoProfile -Command "$env:COMPUTERNAME"
```

### 12.3 Verify user creation

```cmd
net user tux
```

Check the Administrators group:

```cmd
net localgroup Administrators
```

You should see `tux` listed.

### 12.4 Verify SSH service

```cmd
powershell -NoProfile -Command "Get-Service sshd"
```

Check startup type:

```cmd
powershell -NoProfile -Command "Get-Service sshd | Select-Object Name,Status,StartType"
```

Expected state after the `runcmd` runs:

```text
Status: Running
StartType: Automatic
```

### 12.5 Verify RDP setting

```cmd
powershell -NoProfile -Command "Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections'"
```

Expected:

```text
fDenyTSConnections : 0
```

Check firewall rules:

```cmd
powershell -NoProfile -Command "Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Select-Object DisplayName,Enabled"
```

---

## 13. Check Cloudbase-Init logs

Normal Cloudbase-Init log:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 160"
```

Follow it like `tail -f`:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 80 -Wait"
```

Unattend log:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init-unattend.log' -Tail 160"
```

Follow it:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init-unattend.log' -Tail 80 -Wait"
```

Look for:

```text
Metadata service found
Plugins executed
User-data processed
No fatal errors
```

---

## 14. Check Sysprep logs on the new VM

Main Sysprep log:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setupact.log' -Tail 160"
```

Sysprep error log:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Tail 160"
```

---

## 15. Troubleshooting if `C:\status.txt` is missing

### 15.1 Confirm the cloud-init disk is attached

```bash
kubectl get vm vm-windows-from-export -n default -o yaml | grep -A20 -B5 cloudinitdisk
```

You should see both a disk and a volume.

### 15.2 Confirm the Secret has the correct key

```bash
kubectl get secret windows-init-userdata -n default -o yaml
```

The Secret should have:

```yaml
data:
  userdata: ...
```

### 15.3 Restart the VM after patching

If the VM was already running when patched, restart it:

```bash
virtctl stop vm-windows-from-export -n default
virtctl start vm-windows-from-export -n default
```

### 15.4 Check Cloudbase-Init logs

Inside Windows:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 200"
```

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init-unattend.log' -Tail 200"
```

### 15.5 Test with a simpler PowerShell payload

For first validation, `#ps1_sysnative` is easier to verify than full `#cloud-config`.

Create a simple payload:

```bash
cat > /tmp/windows-userdata.yaml <<'EOF'
#ps1_sysnative
New-Item -ItemType Directory -Force C:\cloudbase-test
Set-Content C:\cloudbase-test\hello.txt "cloudbase-init worked"
EOF
```

Update the Secret:

```bash
kubectl create secret generic windows-init-userdata \
  -n default \
  --from-file=userdata=/tmp/windows-userdata.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
```

Restart the VM:

```bash
virtctl stop vm-windows-from-export -n default
virtctl start vm-windows-from-export -n default
```

Verify inside Windows:

```cmd
type C:\cloudbase-test\hello.txt
```

Expected:

```text
cloudbase-init worked
```

If this works but the full `#cloud-config` does not, then the config-drive path is working, but the issue is likely with the specific cloud-config directives.

---

## 16. Important note about `Install-WindowsFeature`

This command is usually for Windows Server:

```yaml
- powershell.exe -Command "Install-WindowsFeature -Name Web-Server -IncludeManagementTools"
```

If your image is Windows Desktop, this command may fail.

That does not necessarily mean Cloudbase-Init failed completely. Check these first:

```cmd
type C:\status.txt
hostname
net user tux
```

The `write_files` and hostname steps may succeed even if the IIS installation command fails later.

---

## 17. Complete command summary

```bash
# Export cloud-init data from Harvester template ConfigMap
kubectl get configmap windows-init -n default -o jsonpath='{.data.cloudInit}' > /tmp/windows-userdata.yaml

# Create Secret for KubeVirt cloud-init
kubectl create secret generic windows-init-userdata \
  -n default \
  --from-file=userdata=/tmp/windows-userdata.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

# Patch VM with cloud-init disk and volume
kubectl patch vm vm-windows-from-export -n default --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/domain/devices/disks/-",
    "value": {
      "name": "cloudinitdisk",
      "disk": {
        "bus": "virtio"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "cloudinitdisk",
      "cloudInitNoCloud": {
        "secretRef": {
          "name": "windows-init-userdata"
        }
      }
    }
  }
]'

# Verify patch
kubectl get vm vm-windows-from-export -n default -o yaml | grep -A20 -B5 cloudinitdisk

# Start VM
virtctl start vm-windows-from-export -n default

# Check VMI and IP
kubectl get vmi vm-windows-from-export -n default -o wide
```

Inside Windows:

```cmd
type C:\status.txt
hostname
net user tux
powershell -NoProfile -Command "Get-Service sshd"
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 160"
```

---

## 18. Expected success state

A successful Step 5 should result in:

```text
The new Windows VM boots from the exported Sysprep image
Windows may reboot several times
Cloudbase-Init reads the cloud-init/config-drive data
C:\status.txt exists
Hostname becomes winserver01
User tux exists
OpenSSH Server is installed and running
RDP is enabled
Cloudbase-Init logs show metadata and user-data processing
```
