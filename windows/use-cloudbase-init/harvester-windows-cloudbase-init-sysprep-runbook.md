# Creating a Windows VM Template with Cloudbase-Init on Harvester

This runbook summarizes the workflow discussed for preparing a Windows VM on Harvester with Cloudbase-Init, running Sysprep, and validating whether Sysprep completed successfully.

The commands below assume you are connected to the Windows VM through SSH and your current shell is `cmd.exe`, for example:

```cmd
administrator@WIN-5HE5GEONR03 C:\Users\Administrator>
```

Because the shell is `cmd.exe`, PowerShell commands are wrapped with:

```cmd
powershell -NoProfile -Command "..."
```

---

## 1. Prerequisites

Before starting this Cloudbase-Init flow, the Windows VM should already have:

- Windows installed on Harvester.
- VirtIO drivers installed.
- Network working.
- SSH access working.
- Administrator access.

Example SSH from Linux:

```bash
ssh Administrator@<windows-vm-ip>
```

If `Invoke-WebRequest` fails with this error:

```text
'Invoke-WebRequest' is not recognized as an internal or external command
```

it means you are in `cmd.exe`, not PowerShell. Use `powershell -Command` as shown below.

---

## 2. Download and install Cloudbase-Init

From the Windows VM `cmd.exe` SSH session:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri 'https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile 'C:\CloudbaseInitSetup_Stable_x64.msi'"
```

Install the MSI silently:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process msiexec.exe -ArgumentList '/i C:\CloudbaseInitSetup_Stable_x64.msi /qn /l*v C:\cloudbase-init-install.log' -Wait"
```

Check the service:

```cmd
powershell -NoProfile -Command "Get-Service *cloudbase*"
```

---

## 3. Back up the original Cloudbase-Init config files

Before overwriting the configuration, back up both files:

```cmd
powershell -NoProfile -Command "Copy-Item 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf' 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf.bak' -Force; Copy-Item 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf' 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf.bak' -Force"
```

---

## 4. Configure `cloudbase-init.conf`

The SUSE KB example uses `username=Admin`. That means Cloudbase-Init will target or create a Windows user named `Admin`.

If you want to use the existing built-in account instead, change:

```ini
username=Admin
```

to:

```ini
username=Administrator
```

Command using the KB-style `Admin` user:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$conf='C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'; @('[DEFAULT]','username=Admin','groups=Administrators','inject_user_password=true','config_drive_raw_hhd=true','config_drive_cdrom=true','config_drive_vfat=true','bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe','mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\','verbose=true','debug=true','logdir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\','logfile=cloudbase-init.log','default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN','logging_serial_port_settings=COM1,115200,N,8','mtu_use_dhcp_config=true','ntp_use_dhcp_config=true','local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\','check_latest_version=true','','metadata_services=cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService,cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.base.EmptyMetadataService') | Set-Content -Path $conf -Encoding ASCII"
```

Verify:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'"
```

---

## 5. Configure `cloudbase-init-unattend.conf`

Command using the KB-style `Admin` user:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$conf='C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf'; @('[DEFAULT]','username=Admin','groups=Administrators','inject_user_password=true','config_drive_raw_hhd=true','config_drive_cdrom=true','config_drive_vfat=true','bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe','mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\','verbose=true','debug=true','logdir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\','logfile=cloudbase-init-unattend.log','default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN','logging_serial_port_settings=COM1,115200,N,8','mtu_use_dhcp_config=true','ntp_use_dhcp_config=true','local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\','plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin','check_latest_version=false','allow_reboot=false','stop_service_on_exit=false','','metadata_services=cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService,cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.base.EmptyMetadataService') | Set-Content -Path $conf -Encoding ASCII"
```

Verify:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf'"
```

---

## 6. Restart and check Cloudbase-Init

Restart the normal Cloudbase-Init service:

```cmd
powershell -NoProfile -Command "Restart-Service cloudbase-init; Get-Service cloudbase-init"
```

Check logs:

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 80"
```

If this current VM was not booted with Harvester cloud-init/config-drive data, it may not find useful metadata yet. That is okay for the template-preparation stage.

---

## 7. Check whether `Unattend.xml` exists

Cloudbase-Init should provide an unattend file under its config directory.

Check:

```cmd
powershell -NoProfile -Command "Test-Path 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml'"
```

Expected output:

```text
True
```

---

## 8. Important Sysprep quoting issue

This command can fail because the `/unattend` path contains spaces:

```cmd
C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown /unattend:"C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"
```

The failure looks like:

```text
SYSPRP ParseCommands:Malformed command line detected; no dash or slash present in option
SYSPRP WinMain: Unable to parse command-line arguments to sysprep; GLE = 0x0
```

To avoid this, copy `Unattend.xml` to a path without spaces:

```cmd
copy "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml" C:\Unattend.xml
```

Verify:

```cmd
dir C:\Unattend.xml
```

---

## 9. Run Sysprep

Run Sysprep directly from `cmd.exe` using the no-space path:

```cmd
C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown /unattend:C:\Unattend.xml
```

This means:

```text
/generalize  -> remove machine-specific identity, SID, and hardware-specific state
/oobe        -> next boot behaves like first boot / OOBE phase
/shutdown    -> shut down the VM when Sysprep finishes
/unattend    -> use the Cloudbase-Init unattend file
```

If Sysprep succeeds, the VM should shut down automatically.

Expected successful flow:

```text
Sysprep runs
SSH session appears stuck or waits
Windows shuts down
SSH disconnects
Harvester VM becomes Stopped
```

---

## 10. If a previous Sysprep command is stuck

If you previously ran Sysprep with bad quoting and it is stuck, check:

```cmd
powershell -NoProfile -Command "Get-Process sysprep -ErrorAction SilentlyContinue"
```

If needed, stop it before retrying with the corrected command:

```cmd
powershell -NoProfile -Command "Stop-Process -Name sysprep -Force -ErrorAction SilentlyContinue"
```

Do this only for the known failed/stuck parse-error case. Do not kill Sysprep if it is actively progressing through `generalize`.

---

## 11. Monitor Sysprep progress

### Check whether Sysprep is still running

```cmd
powershell -NoProfile -Command "Get-Process sysprep -ErrorAction SilentlyContinue"
```

If it prints a `sysprep` process, Sysprep is still running.

### Show the latest main Sysprep log

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setupact.log' -Tail 120"
```

### Follow the main log like `tail -f`

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setupact.log' -Tail 80 -Wait"
```

Stop following with:

```text
Ctrl + C
```

### Show the latest Sysprep error log

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Tail 120"
```

### Follow the error log like `tail -f`

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Tail 80 -Wait"
```

If `setuperr.log` does not print anything new for a while, that only means no new error has been appended. It does not necessarily mean Sysprep is stuck.

### Check whether the log file is still being updated

```cmd
powershell -NoProfile -Command "Get-Item 'C:\Windows\System32\Sysprep\Panther\setupact.log' | Select-Object LastWriteTime,Length"
```

Run it again later. If `LastWriteTime` or `Length` changes, Sysprep is still progressing.

---

## 12. How to interpret the logs we saw

### Old parse errors

These were from the earlier incorrect Sysprep command:

```text
SYSPRP WinMain: Unable to parse command-line arguments to sysprep; GLE = 0x0
```

If they are timestamped before the corrected run, they can be ignored.

### Current-run `ERROR_ACCESS_DENIED` during `UnloadStore`

This was observed:

```text
CSI HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED) from UnloadStore(target = NULL)
```

This is not ideal, but it does not by itself prove the Sysprep run failed, especially if `setupact.log` continues afterward.

In the observed run, `setupact.log` showed Sysprep continued into the `generalize` phase:

```text
SYSPRP WinMain:Processing 'generalize' internal provider request.
SYSPRP SysprepSession::Execute: Beginning action execution from C:\Windows\System32\Sysprep\ActionFiles\Generalize.xml
```

So the best action is to keep monitoring until one of these happens:

```text
Success case:
  VM shuts down automatically
  SSH disconnects
  Harvester VM becomes Stopped

Failure case:
  sysprep process disappears
  VM does not shut down
  setuperr.log receives newer fatal errors
```

---

## 13. Check VM shutdown from Linux / Harvester side

From your Linux host with kubeconfig access:

```bash
kubectl get vmi -A
```

If the Windows VM no longer appears as a VMI, it likely shut down.

Check the VM printable status:

```bash
kubectl get vm -n <namespace> <vm-name> -o jsonpath='{.status.printableStatus}{"\n"}'
```

Expected:

```text
Stopped
```

Example namespace:

```bash
kubectl get vm -n default <vm-name> -o jsonpath='{.status.printableStatus}{"\n"}'
```

One caveat: if the VM is configured to auto-start or has a run strategy that restarts it, Harvester/KubeVirt may start it again after guest shutdown. For a template-preparation flow, the VM should normally remain stopped.

---

## 14. Next Harvester steps after successful Sysprep

After Sysprep completes and the VM is stopped:

1. Do not boot this source VM again unless needed.
2. In Harvester, create or export an image from the VM root disk/volume.
3. Use that new image as the Windows base image/template.
4. Create a new Windows VM from the prepared image.
5. Add Harvester cloud-init/user-data to the new VM.
6. Boot the new VM and verify that Cloudbase-Init consumes the config drive/user-data.

---

## 15. Simple Cloudbase-Init user-data test

When creating a new VM from the prepared image, use a simple PowerShell user-data test:

```powershell
#ps1_sysnative
New-Item -ItemType Directory -Force C:\cloudbase-test
Set-Content C:\cloudbase-test\hello.txt "cloudbase-init worked"
```

After the VM boots, log in and check:

```cmd
type C:\cloudbase-test\hello.txt
```

Expected output:

```text
cloudbase-init worked
```

If the file exists, Cloudbase-Init successfully consumed the user-data.

---

## 16. Useful troubleshooting commands

### Check Cloudbase-Init service

```cmd
powershell -NoProfile -Command "Get-Service *cloudbase*"
```

### Restart Cloudbase-Init

```cmd
powershell -NoProfile -Command "Restart-Service cloudbase-init; Get-Service cloudbase-init"
```

### Check Cloudbase-Init log

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log' -Tail 120"
```

### Check Cloudbase-Init unattend log

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init-unattend.log' -Tail 120"
```

### Check Sysprep process

```cmd
powershell -NoProfile -Command "Get-Process sysprep -ErrorAction SilentlyContinue"
```

### Check Sysprep main log

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setupact.log' -Tail 120"
```

### Check Sysprep error log

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Tail 120"
```

### Follow Sysprep main log

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setupact.log' -Tail 80 -Wait"
```

### Follow Sysprep error log

```cmd
powershell -NoProfile -Command "Get-Content 'C:\Windows\System32\Sysprep\Panther\setuperr.log' -Tail 80 -Wait"
```

---

## 17. Summary

The key points are:

- Run PowerShell commands through `powershell -NoProfile -Command` if your SSH session is in `cmd.exe`.
- Configure both:
  - `cloudbase-init.conf`
  - `cloudbase-init-unattend.conf`
- Use `NoCloudConfigDriveService` and `ConfigDriveService` metadata services for Harvester/KubeVirt-style config drive usage.
- Avoid Sysprep `/unattend` paths with spaces by copying `Unattend.xml` to `C:\Unattend.xml`.
- Run Sysprep as:

```cmd
C:\Windows\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown /unattend:C:\Unattend.xml
```

- If successful, the Windows VM shuts down automatically.
- After shutdown, create a reusable Harvester image/template from the VM disk.
- Test a new VM with simple `#ps1_sysnative` user-data.
