# Harvester Windows Cloudbase-Init CLI Runbook from Scratch

This runbook merges the tested notes for creating a Windows VM image on Harvester with Cloudbase-Init, sealing it with Sysprep, creating a new VM from the sealed disk, and applying user-data through Kubernetes/KubeVirt CLI as much as possible.

The flow is:

1. Prepare a source Windows VM.
2. Install and configure Cloudbase-Init.
3. Run Sysprep and shut down the source VM.
4. Create or export a reusable Harvester image from the source VM disk.
5. Create a new Windows VM from that image.
6. Attach cloud-init/config-drive user-data from a Kubernetes Secret.
7. Boot and verify Cloudbase-Init inside Windows.

## Example Values

Replace these with your environment values before running commands.

```text
Namespace: default
Source VM: windows-vm
New VM: vm-windows-from-export
Cloud Config Template ConfigMap: windows-init
Cloud-init Secret: windows-init-userdata
Windows admin user: Administrator
Cloudbase target user: Administrator
```

CLI tools used from Linux:

```text
kubectl
virtctl
ssh
nc, optional
```

Windows commands assume you are connected to the Windows VM through SSH and your shell prompt is `cmd.exe`, for example:

```cmd
administrator@WIN-5HE5GEONR03 C:\Users\Administrator>
```

Because the SSH shell is usually `cmd.exe`, PowerShell commands are wrapped like this:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "..."
```

## 1. Prepare the Source Windows VM

Create the first Windows VM in Harvester from the Windows installation ISO. This first VM is the image-building VM. It should have:

- Windows installed.
- VirtIO storage and network drivers installed.
- Network connectivity.
- Administrator access.
- Optional but useful: OpenSSH Server enabled.

Check the VM from Linux:

```bash
kubectl get vm -n default windows-vm
kubectl get vmi -n default windows-vm -o wide
```

If the VMI does not show an IP, check inside Windows with:

```cmd
ipconfig
```

## 2. Optional: Enable SSH in the Source Windows VM

If you do not already have SSH access, open PowerShell as Administrator through console or RDP and run:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service sshd -StartupType Automatic
New-NetFirewallRule -DisplayName "Allow SSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow
Get-Service sshd
```

From Linux, connect directly:

```bash
ssh Administrator@<windows-vm-ip>
```

If direct network access does not work but Kubernetes API access works, use KubeVirt port-forwarding:

```bash
virtctl port-forward vm/windows-vm/default 2222:22
```

In another terminal:

```bash
ssh Administrator@127.0.0.1 -p 2222
```

## 3. Download and Install Cloudbase-Init

Run these from the Windows VM `cmd.exe` SSH session:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri 'https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile 'C:\CloudbaseInitSetup_Stable_x64.msi'"
```

Install silently:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process msiexec.exe -ArgumentList '/i C:\CloudbaseInitSetup_Stable_x64.msi /qn /l*v C:\cloudbase-init-install.log' -Wait"
```

Check the service:

```cmd
powershell -NoProfile -Command "Get-Service *cloudbase*"
```

## 4. Configure Cloudbase-Init

Back up the generated configuration files first:

```cmd
powershell -NoProfile -Command "Copy-Item 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf' 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf.bak' -Force; Copy-Item 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf' 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf.bak' -Force"
```

This runbook uses the built-in Administrator account for Cloudbase-Init:

```ini
username=Administrator
```

That means Cloudbase-Init targets the existing built-in Windows Administrator account.

### 4.1 Write `cloudbase-init.conf`

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$conf='C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'; @('[DEFAULT]','username=Administrator','groups=Administrators','inject_user_password=true','config_drive_raw_hhd=true','config_drive_cdrom=true','config_drive_vfat=true','bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe','mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\','verbose=true','debug=true','logdir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\','logfile=cloudbase-init.log','default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN','logging_serial_port_settings=COM1,115200,N,8','mtu_use_dhcp_config=true','ntp_use_dhcp_config=true','local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\','check_latest_version=true','','metadata_services=cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService,cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.base.EmptyMetadataService') | Set-Content -Path $conf -Encoding ASCII"
```

Verify:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'"
```

### 4.2 Write `cloudbase-init-unattend.conf`

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$conf='C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf'; @('[DEFAULT]','username=Administrator','groups=Administrators','inject_user_password=true','config_drive_raw_hhd=true','config_drive_cdrom=true','config_drive_vfat=true','bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe','mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\','verbose=true','debug=true','logdir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\','logfile=cloudbase-init-unattend.log','default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN','logging_serial_port_settings=COM1,115200,N,8','mtu_use_dhcp_config=true','ntp_use_dhcp_config=true','local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\','plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin','check_latest_version=false','allow_reboot=false','stop_service_on_exit=false','','metadata_services=cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService,cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.base.EmptyMetadataService') | Set-Content -Path $conf -Encoding ASCII"
```

Verify:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf'"
```

Restart and check Cloudbase-Init:

```cmd
powershell -NoProfile -Command "Restart-Service cloudbase-init; Get-Service cloudbase-init"
```

Check logs:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 80"
```

If the source VM was not booted with config-drive data, Cloudbase-Init may not find useful metadata yet. That is okay at this stage.

## 5. Run Sysprep on the Source VM

Check that Cloudbase-Init installed `Unattend.xml`:

```cmd
powershell -NoProfile -Command "Test-Path 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml'"
```

Expected:

```text
True
```

The `/unattend` path can fail when it contains spaces, even when quoted. A failure can look like:

```text
SYSPRP ParseCommands:Malformed command line detected; no dash or slash present in option
SYSPRP WinMain: Unable to parse command-line arguments to sysprep; GLE = 0x0
```

Avoid that by copying `Unattend.xml` to a path without spaces:

```cmd
copy "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml" C:\Unattend.xml
dir C:\Unattend.xml
```

Run Sysprep:

```cmd
C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown /unattend:C:\Unattend.xml
```

Meaning:

```text
/generalize  remove machine-specific identity, SID, and hardware-specific state
/oobe        next boot enters first-boot/OOBE flow
/shutdown    shut down when Sysprep finishes
/unattend    use the Cloudbase-Init unattend file
```

If Sysprep succeeds:

```text
Sysprep runs
SSH pauses or disconnects
Windows shuts down
Harvester VM becomes Stopped
```

## 6. Monitor Sysprep

Check whether Sysprep is still running:

```cmd
powershell -NoProfile -Command "Get-Process sysprep -ErrorAction SilentlyContinue"
```

Show the latest main Sysprep log:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setupact.log' -Tail 120"
```

Follow the main log:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setupact.log' -Tail 80 -Wait"
```

Stop following with:

```text
Ctrl + C
```

Show the latest Sysprep error log:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Tail 120"
```

Check whether the main log is still being updated:

```cmd
powershell -NoProfile -Command "Get-Item 'C:\Windows\System32\Sysprep\Panther\setupact.log' | Select-Object LastWriteTime,Length"
```

Run it again later. If `LastWriteTime` or `Length` changes, Sysprep is still progressing.

If a previous bad Sysprep command is stuck from the quoting issue, check:

```cmd
powershell -NoProfile -Command "Get-Process sysprep -ErrorAction SilentlyContinue"
```

Stop only the known failed/stuck parse-error case:

```cmd
powershell -NoProfile -Command "Stop-Process -Name sysprep -Force -ErrorAction SilentlyContinue"
```

Do not kill Sysprep if it is actively progressing through `generalize`.

## 7. Confirm Shutdown from Linux

From Linux with kubeconfig access:

```bash
kubectl get vmi -A
```

If the Windows VM no longer appears as a VMI, it likely shut down.

Check VM printable status:

```bash
kubectl get vm -n default windows-vm -o jsonpath='{.status.printableStatus}{"\n"}'
```

Expected:

```text
Stopped
```

If the VM auto-starts after guest shutdown, check its run strategy. For a source image-preparation VM, it should normally remain stopped after Sysprep.

## 8. Create the Reusable Harvester Image

After Sysprep succeeds and the source VM is stopped:

1. Do not boot the source VM again unless you intentionally want to modify the image.
2. Create or export a Harvester image from the source VM root disk/volume.
3. Use that exported/prepared image as the base image for new Windows VMs.

The exact export step is usually done through Harvester image/volume operations. The CLI parts in the rest of this document assume a new VM named `vm-windows-from-export` already exists from that prepared image and is currently stopped.

Check the new VM:

```bash
kubectl get vm -n default vm-windows-from-export
kubectl get vm -n default vm-windows-from-export -o yaml
```

## 9. Prepare First-Boot User-Data

For first validation, use a small PowerShell payload. It is easier to debug than full cloud-config:

```bash
cat > /tmp/windows-userdata.yaml <<'EOF'
#ps1_sysnative
New-Item -ItemType Directory -Force C:\cloudbase-test
Set-Content C:\cloudbase-test\hello.txt "cloudbase-init worked"
EOF
```

Create or update the Secret. KubeVirt expects the user-data key to be named `userdata`.

```bash
kubectl create secret generic windows-init-userdata \
  -n default \
  --from-file=userdata=/tmp/windows-userdata.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify:

```bash
kubectl get secret windows-init-userdata -n default
kubectl get secret windows-init-userdata -n default -o yaml
```

You should see:

```yaml
data:
  userdata: ...
```

## 10. Alternative Full Cloud-Config User-Data

After the simple `#ps1_sysnative` test works, you can use cloud-config.

Important Cloudbase-Init details:

- Use `passwd`, not `password`, for local user passwords.
- Omit `encoding` for plain text `write_files` content. Use `encoding` only for supported encoded content such as base64 or gzip.
- `Install-WindowsFeature` is usually Windows Server only. It may fail on Windows Desktop editions.

Example:

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
users:
  - name: tux
    passwd: StrongPassw0rd
    groups:
      - Administrators
runcmd:
  - powershell.exe -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
  - powershell.exe -Command "Start-Service sshd"
  - powershell.exe -Command "Set-Service -Name sshd -StartupType Automatic"
  - powershell.exe -Command "New-NetFirewallRule -DisplayName 'Allow SSH' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow"
  - powershell.exe -Command "Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0"
  - powershell.exe -Command "Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'"
EOF
```

Optional Windows Server IIS command:

```yaml
  - powershell.exe -Command "Install-WindowsFeature -Name Web-Server -IncludeManagementTools"
```

Apply the updated Secret:

```bash
kubectl create secret generic windows-init-userdata \
  -n default \
  --from-file=userdata=/tmp/windows-userdata.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
```

## 11. Attach the Cloud-Init Disk to the New VM

Before patching, check whether `cloudinitdisk` already exists:

```bash
kubectl get vm vm-windows-from-export -n default -o yaml | grep -A20 -B5 cloudinitdisk
```

If nothing is returned, patch the VM with a NoCloud config-drive disk:

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

Verify:

```bash
kubectl get vm vm-windows-from-export -n default -o yaml | grep -A20 -B5 cloudinitdisk
```

You should see one disk:

```yaml
- disk:
    bus: virtio
  name: cloudinitdisk
```

And one matching volume:

```yaml
- name: cloudinitdisk
  cloudInitNoCloud:
    secretRef:
      name: windows-init-userdata
```

If you accidentally add duplicates, edit the VM and keep only one `cloudinitdisk` entry under both `spec.template.spec.domain.devices.disks` and `spec.template.spec.volumes`:

```bash
kubectl edit vm vm-windows-from-export -n default
```

## 12. Alternative: Use `cloudInitConfigDrive`

The Cloudbase-Init config above enables both services:

```ini
cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService
cloudbaseinit.metadata.services.configdrive.ConfigDriveService
```

The `cloudInitNoCloud` KubeVirt volume is the usual first choice. If you want to test the ConfigDrive path explicitly, use `cloudInitConfigDrive` instead of `cloudInitNoCloud`:

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

Use either `cloudInitNoCloud` or `cloudInitConfigDrive` for the same disk, not both.

## 13. Start the New VM

If the VM has:

```yaml
spec:
  runStrategy: Halted
```

start it:

```bash
virtctl start vm-windows-from-export -n default
```

Or patch the run strategy:

```bash
kubectl patch vm vm-windows-from-export -n default --type=merge -p '{"spec":{"runStrategy":"RerunOnFailure"}}'
```

Watch status:

```bash
kubectl get vm vm-windows-from-export -n default
kubectl get vmi vm-windows-from-export -n default -o wide
watch -n 2 "kubectl get vm,vmi -n default | grep vm-windows-from-export"
```

After booting from the Syspreped image, Windows may reboot several times while it finishes:

```text
Sysprep specialize phase
OOBE phase
Cloudbase-Init unattend phase
Cloudbase-Init normal service phase
Cloud configuration execution
```

Wait until the VM is stable and reachable through console, RDP, or SSH.

## 14. Check the New VM IP

From Kubernetes:

```bash
kubectl get vmi vm-windows-from-export -n default -o wide
kubectl get vmi vm-windows-from-export -n default -o jsonpath='{.status.interfaces[*].ipAddress}{"\n"}'
```

Inside Windows:

```cmd
ipconfig
ipconfig /all
```

PowerShell IPv4 summary:

```cmd
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,IPAddress,PrefixLength"
```

## 15. Verify Cloudbase-Init Inside Windows

For the simple PowerShell payload:

```cmd
type C:\cloudbase-test\hello.txt
```

Expected:

```text
cloudbase-init worked
```

For the cloud-config payload:

```cmd
type C:\status.txt
hostname
net user tux
net localgroup Administrators
```

Expected signals:

```text
C:\status.txt contains Initial Configuration Concluded!
hostname is winserver01
tux exists
tux is in Administrators
```

Check SSH:

```cmd
powershell -NoProfile -Command "Get-Service sshd | Select-Object Name,Status,StartType"
powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort 22 -State Listen"
```

Check RDP:

```cmd
powershell -NoProfile -Command "Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections'"
powershell -NoProfile -Command "Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Select-Object DisplayName,Enabled"
```

## 16. Review Logs

Cloudbase-Init normal log:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 160"
```

Follow it:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 80 -Wait"
```

Cloudbase-Init unattend log:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init-unattend.log' -Tail 160"
```

Sysprep logs:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setupact.log' -Tail 160"
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Tail 160"
```

Good signs:

```text
Metadata service found
User-data processed
No fatal errors
Expected reboot requested by hostname or runcmd handling
```

## 17. Troubleshooting

If `C:\cloudbase-test\hello.txt` or `C:\status.txt` is missing, first confirm the cloud-init disk is attached:

```bash
kubectl get vm vm-windows-from-export -n default -o yaml | grep -A20 -B5 cloudinitdisk
```

Confirm the Secret key is `userdata`:

```bash
kubectl get secret windows-init-userdata -n default -o yaml
```

Restart the VM if it was already running when patched:

```bash
virtctl stop vm-windows-from-export -n default
virtctl start vm-windows-from-export -n default
```

Check Cloudbase-Init logs:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 200"
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init-unattend.log' -Tail 200"
```

If the simple `#ps1_sysnative` test works but full `#cloud-config` does not, the config-drive path is working and the issue is probably in the cloud-config content.

Common cloud-config issues:

- `password` is not the Cloudbase-Init user password key. Use `passwd`.
- Plain text `write_files` does not need `encoding: utf-8`.
- `Install-WindowsFeature` may fail on Windows Desktop.
- `set_hostname` may request a reboot.
- `runcmd` commands run under `cmd.exe`, so quote PowerShell commands carefully.

If direct SSH fails from Linux:

```bash
nc -vz <windows-vm-ip> 22
ssh -vvv Administrator@<windows-vm-ip>
```

Inside Windows:

```cmd
powershell -NoProfile -Command "Get-Service sshd"
powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort 22 -State Listen"
netstat -ano | findstr :22
```

Meaning:

```text
Connection refused: Windows is reachable, but SSH is not listening.
Connection timed out: firewall, routing, VM network, or LAN reachability problem.
Permission denied: network and service work, but authentication failed.
```

## 18. Complete Command Summary

Source VM, inside Windows:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri 'https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile 'C:\CloudbaseInitSetup_Stable_x64.msi'"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process msiexec.exe -ArgumentList '/i C:\CloudbaseInitSetup_Stable_x64.msi /qn /l*v C:\cloudbase-init-install.log' -Wait"
powershell -NoProfile -Command "Get-Service *cloudbase*"
copy "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml" C:\Unattend.xml
C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown /unattend:C:\Unattend.xml
```

New VM, from Linux:

```bash
cat > /tmp/windows-userdata.yaml <<'EOF'
#ps1_sysnative
New-Item -ItemType Directory -Force C:\cloudbase-test
Set-Content C:\cloudbase-test\hello.txt "cloudbase-init worked"
EOF

kubectl create secret generic windows-init-userdata \
  -n default \
  --from-file=userdata=/tmp/windows-userdata.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

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

virtctl start vm-windows-from-export -n default
kubectl get vmi vm-windows-from-export -n default -o wide
```

New VM, inside Windows:

```cmd
type C:\cloudbase-test\hello.txt
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 160"
```

## References

- SUSE KB: <https://support.scc.suse.com/s/kb/Creating-Windows-VMs-with-Cloudbase-Init-in-Harvester?language=en_US>
- KubeVirt startup scripts: <https://kubevirt.io/user-guide/user_workloads/startup_scripts/>
- Cloudbase-Init userdata docs: <https://cloudbase-init.readthedocs.io/en/latest/userdata.html>
- Cloudbase-Init services docs: <https://cloudbase-init.readthedocs.io/en/latest/services.html>
