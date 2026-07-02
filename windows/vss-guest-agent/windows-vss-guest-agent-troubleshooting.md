# Windows VSS & QEMU Guest Agent Troubleshooting Guide

## Overview

This guide addresses Windows VSS (Volume Shadow Copy Service) issues with KubeVirt snapshots, specifically the error:
```
failed to add \\?\Volume{9c24dfaf-a611-4b06-bd60-e4fe3e7103da}\ to snapshot set
```

## Understanding the Architecture

### How QEMU Guest Agent Uses VSS

```
KubeVirt → QEMU Guest Agent → Windows VSS APIs → Filesystem Freeze
```

1. **KubeVirt calls the QEMU Guest Agent** via libvirt commands like `guest-fsfreeze-freeze`
2. **The guest agent translates this to OS-specific calls**:
   - On **Linux**: Uses `fsfreeze` syscalls
   - On **Windows**: Uses **VSS (Volume Shadow Copy Service)** APIs
3. **VSS Integration Process**: Guest agent calls VSS to create a snapshot set, VSS tries to add volumes to the snapshot set (this is where the error occurs)

### Important Windows Behavior Note

**When QEMU Guest Agent is installed on Windows but VSS is disabled or unavailable:**
- The `guest-fsfreeze-freeze` command will **NOT fail** immediately
- Instead, it will return success but **perform no actual filesystem freezing**
- This means `virt-freezer` in KubeVirt will execute without errors
- However, **the snapshot will be crash-consistent only, not application-consistent**
- No filesystem buffers will be flushed, and applications won't be notified

This is different from Linux where filesystem freezing is handled at the kernel level and will fail if the operation cannot be performed.

### What's Included by Default

| Component | Windows Status | Installation Required |
|-----------|---------------|----------------------|
| **VSS (Volume Shadow Copy Service)** | ✅ Built into Windows (Server 2003+, Vista+) | No |
| **QEMU Guest Agent** | ❌ Not included | Yes |
| **VSS Support in Guest Agent** | ❌ Must be compiled with VSS support | Yes (via virtio-win) |

## VSS Impact on Longhorn PVC Snapshots

### How VSS Enables Data Quiescing

**VSS is Windows' built-in data quiescing mechanism** that coordinates between applications, filesystem, and storage to create consistent snapshots.

#### The VSS Quiescing Process

When KubeVirt calls `guest-fsfreeze-freeze` with VSS properly enabled:

```
1. QEMU Guest Agent → VSS Coordinator
2. VSS Coordinator → VSS Writers (applications)
3. VSS Writers prepare for snapshot:
   • Flush dirty buffers to disk
   • Complete pending transactions  
   • Reach application-consistent state
   • Signal ready for snapshot
4. VSS Coordinator → Filesystem
5. Filesystem flushes metadata and journals
6. VSS signals "frozen" state to guest agent
7. Guest agent reports success to KubeVirt
8. Longhorn creates the storage snapshot
9. VSS thaws the system back to normal
```

#### What Gets Quiesced with VSS

**Application Level:**
- **SQL Server**: Completes transactions, flushes log buffers
- **Exchange**: Finishes mail operations, flushes databases  
- **Active Directory**: Completes replication, flushes logs
- **Custom Applications**: Those with VSS writers participate

**Filesystem Level:**
- **NTFS**: Flushes metadata, completes journal entries
- **File Cache**: Dirty pages written to disk
- **Registry**: Pending changes committed

**System Level:**
- **Memory Buffers**: Flushed to storage
- **I/O Operations**: Completed or held
- **Volume Locks**: Coordinated across applications

### VSS vs. No-VSS Comparison

| Aspect | With VSS (Quiesced) | Without VSS (Not Quiesced) |
|--------|-------------------|---------------------------|
| **Applications** | ✅ Notified, reach consistent state | ❌ Unaware, may be mid-operation |
| **Dirty Buffers** | ✅ Flushed to disk | ❌ Remain in memory |
| **Transactions** | ✅ Completed or properly rolled back | ❌ May be captured mid-transaction |
| **File Operations** | ✅ Completed or properly paused | ❌ May result in partial writes |
| **Database Consistency** | ✅ Transaction logs consistent | ❌ Logs and data may be mismatched |
| **Recovery Needed** | ✅ Clean boot, no repairs | ❌ May need chkdsk, database recovery |

### Real-World Example: SQL Server Database

**With VSS Enabled (Quiesced):**
```
1. SQL Server VSS Writer receives freeze request
2. SQL Server flushes all dirty pages to disk
3. Transaction log is brought to consistent state  
4. SQL Server signals "ready for snapshot"
5. Snapshot is taken with database in consistent state
6. On restore: Database comes online immediately
```

**Without VSS (Not Quiesced):**
```
1. SQL Server continues normal operations
2. Some transactions may be mid-commit
3. Dirty pages remain in memory  
4. Snapshot captures inconsistent state
5. On restore: SQL Server detects corruption
6. Database may need emergency repairs or be unrecoverable
```

### Scenario: KubeVirt VM with Longhorn PVC, VSS Disabled

When you have a KubeVirt VM using a Longhorn PVC (which supports snapshots) but VSS is disabled on the Windows guest:

#### What Happens During Snapshot Creation

1. **KubeVirt's virt-freezer executes successfully** (no error thrown)
2. **Guest filesystem is NOT quiesced** - this is the critical issue
3. **Longhorn CSI snapshot still gets created** at the storage layer
4. **Result: Crash-consistent snapshot only**

#### Two-Level Consistency Problem

```
┌─────────────────────────────────────────────┐
│           Guest OS Layer                    │
│  ┌─────────────────────────────────────────┐│
│  │    Applications & Filesystem            ││  ← NOT quiesced (VSS disabled)
│  │  • Dirty buffers in memory              ││
│  │  • Pending transactions                 ││
│  │  • Application state inconsistent       ││
│  └─────────────────────────────────────────┘│
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│          Storage Layer                      │
│  ┌─────────────────────────────────────────┐│
│  │       Longhorn Volume                   ││  ← Snapshot IS created
│  │  • Storage-level consistency ✓         ││
│  │  • Block-level atomicity ✓             ││
│  │  • BUT: Guest data inconsistent ✗      ││
│  └─────────────────────────────────────────┘│
└─────────────────────────────────────────────┘
```

#### Data Consistency Levels Explained

| Consistency Level | Description | VSS Required? | Longhorn Snapshot | Risk Level |
|-------------------|-------------|---------------|-------------------|------------|
| **Crash-consistent** | Snapshot taken without guest coordination | ❌ No | ✅ Works | 🟡 Medium |
| **Filesystem-consistent** | Guest filesystem buffers flushed | ✅ Yes | ✅ Works | 🟢 Low |
| **Application-consistent** | Applications notified to reach safe state | ✅ Yes | ✅ Works | 🟢 Very Low |

#### Specific Risks with VSS Disabled

**Database Applications:**
- Incomplete transactions may be captured mid-write
- Database logs and data files may be inconsistent
- Recovery may require manual intervention

**File Operations:**
- Files being written may be corrupted or truncated
- Metadata updates may be incomplete
- NTFS journal may be inconsistent

**Application State:**
- Applications unaware of snapshot timing
- Memory buffers not flushed to disk
- Configuration changes may be partially applied

### Storage vs. Guest Consistency

This scenario highlights an important distinction:

**Longhorn (Storage) Perspective:**
- ✅ Snapshot creation succeeds
- ✅ Storage-level consistency maintained
- ✅ All blocks captured atomically
- ✅ No storage corruption

**Guest OS Perspective:**
- ❌ Filesystem not quiesced
- ❌ Applications not notified
- ❌ Dirty buffers may be lost
- ❌ Data consistency not guaranteed

### Impact on Restore Operations

When restoring from such snapshots:

1. **VM will boot successfully** (storage is intact)
2. **Filesystem may require repair** (fsck/chkdsk)
3. **Applications may detect corruption** and trigger recovery
4. **Some data loss is possible** (anything in memory buffers)

## Diagnostic Steps

### 1. Check Guest Agent Connection Status in KubeVirt

```bash
# Check VMI status for agent connection
kubectl describe vmi <your-windows-vm-name> -n <namespace>

# Look specifically for AgentConnected condition
kubectl get vmi <your-windows-vm-name> -n <namespace> -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}'

# Expected result: Should show "True" if the guest agent is connected
```

### 2. Check Guest Agent Information via KubeVirt

```bash
# Get detailed guest OS info (this tests agent communication)
kubectl get --raw "/api/v1/namespaces/<namespace>/virtualmachineinstances/<vm-name>/guestosinfo" | jq .

# Check supported guest agent commands
kubectl get vmi <your-vm-name> -n <namespace> -o jsonpath='{.status.guestOSInfo}'

# Check filesystem freeze status specifically
kubectl get vmi <your-vm-name> -n <namespace> -o jsonpath='{.status.guestOSInfo.fsFreezeStatus}'
```

### 3. Windows Guest VM Diagnostics

#### Check QEMU Guest Agent Service

```powershell
# Check if service is installed and running
Get-Service "QEMU Guest Agent" -ErrorAction SilentlyContinue

# If not found, check alternative names
Get-Service | Where-Object {$_.Name -like "*qemu*" -or $_.DisplayName -like "*guest*"}

# Check service status details
sc query "QEMU Guest Agent"
sc qc "QEMU Guest Agent"
```

#### Verify VSS Integration

```powershell
# Check VSS service status
Get-Service VSS
Get-Service SWPRV

# List VSS writers (should include QEMU if properly configured)
vssadmin list writers

# Check for QEMU-related VSS providers
vssadmin list providers | findstr -i qemu

# Check VSS shadow storage
vssadmin list shadowstorage
```

#### Check Guest Agent Installation

```powershell
# Check if guest agent executable exists
Test-Path "C:\Program Files\Qemu-ga\qemu-ga.exe"
Test-Path "C:\Program Files\QEMU Guest Agent\qemu-ga.exe"

# Check registry for installation
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object {$_.DisplayName -like "*qemu*" -or $_.DisplayName -like "*virtio*"}

# Check guest agent version (if installed)
& "C:\Program Files\Qemu-ga\qemu-ga.exe" --version
```

### 4. Check KubeVirt Logs for Details

```bash
# Check virt-handler logs for guest agent issues
kubectl logs -n kubevirt $(kubectl get pods -n kubevirt -l kubevirt.io=virt-handler --field-selector spec.nodeName=<node-where-vm-runs> -o name) | grep -i "guest\|agent\|freeze"

# Check virt-launcher logs for the specific VM
kubectl logs -n <namespace> $(kubectl get pods -n <namespace> -l kubevirt.io=virt-launcher,kubevirt.io/created-by=<vm-uid> -o name) | grep -i "guest\|agent\|freeze"
```

### 5. Test Freeze Operation Manually

```bash
# Try to freeze the VM manually using virt-freezer
kubectl exec -n <namespace> $(kubectl get pods -n <namespace> -l kubevirt.io=virt-launcher,kubevirt.io/created-by=<vm-uid> -o name) -- /usr/bin/virt-freezer --freeze --namespace <namespace> --name <vm-name>

# Check freeze status
kubectl exec -n <namespace> $(kubectl get pods -n <namespace> -l kubevirt.io=virt-launcher,kubevirt.io/created-by=<vm-uid> -o name) -- /usr/bin/virt-freezer --unfreeze --namespace <namespace> --name <vm-name>
```

## Installation Solutions

### Option 1: VirtIO Driver Package (Recommended)

The Fedora virtio-win guest-tools installer includes the VirtIO drivers, QEMU
Guest Agent, and QEMU Guest Agent VSS provider. Run the following commands
inside the Windows VM from **64-bit PowerShell as Administrator**.

> Before changing storage drivers on an existing production VM, take a backup
> or crash-consistent snapshot and confirm that you have console access.

#### Download and install the stable guest-tools bundle

```powershell
# Confirm that this PowerShell session is elevated.
$isAdmin = ([Security.Principal.WindowsPrincipal](
    [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Open PowerShell with 'Run as administrator' and run the commands again."
}

# Use the stable release URL. The URL redirects to the current stable build.
$downloadUrl = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win-guest-tools.exe"
$installer = Join-Path $env:TEMP "virtio-win-guest-tools.exe"

# Download the installer. On older Windows PowerShell, TLS 1.2 may need to be
# enabled explicitly before Invoke-WebRequest is called.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $downloadUrl -OutFile $installer -UseBasicParsing

# Verify that Windows considers the publisher signature valid.
$signature = Get-AuthenticodeSignature -FilePath $installer
$signature | Format-List Status, StatusMessage, SignerCertificate
if ($signature.Status -ne "Valid") {
    throw "Installer signature is not valid; installation stopped."
}

# Optional: record the SHA-256 hash for auditing.
Get-FileHash -Path $installer -Algorithm SHA256

# Install the bundle silently and suppress an automatic reboot.
# Run the EXE directly; do not pass this bundle to msiexec.exe.
$process = Start-Process -FilePath $installer `
    -ArgumentList "/install", "/quiet", "/norestart" `
    -Wait -PassThru

# 0 = success; 3010 = success, but Windows must be restarted.
if ($process.ExitCode -notin 0, 3010) {
    throw "virtio-win installation failed with exit code $($process.ExitCode)."
}
Write-Host "Installer exit code: $($process.ExitCode)"
```

For an interactive installation, replace the `Start-Process` command above
with:

```powershell
Start-Process -FilePath $installer -ArgumentList "/install" -Wait
```

Keep the default QEMU Guest Agent and VSS provider components selected. The
installer installs only drivers applicable to the VM's detected devices.

#### Offline installation from a mounted virtio-win ISO

If the VM has no Internet access, download
[`virtio-win.iso`](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)
elsewhere and attach it to the VM as a CD-ROM. Then run:

```powershell
# Locate the guest-tools bundle on the attached CD-ROM.
$guestTools = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=5" |
    ForEach-Object { Join-Path $_.DeviceID "virtio-win-guest-tools.exe" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if (-not $guestTools) {
    throw "virtio-win-guest-tools.exe was not found on an attached CD-ROM."
}

$process = Start-Process -FilePath $guestTools `
    -ArgumentList "/install", "/quiet", "/norestart" `
    -Wait -PassThru
if ($process.ExitCode -notin 0, 3010) {
    throw "virtio-win installation failed with exit code $($process.ExitCode)."
}
```

If the ISO does not contain the bundle, install its 64-bit MSI packages
directly:

```powershell
# Replace D: if the virtio-win ISO uses a different drive letter.
$driverInstall = Start-Process msiexec.exe `
    -ArgumentList '/i', 'D:\virtio-win-gt-x64.msi', '/qn', '/norestart' `
    -Wait -PassThru
if ($driverInstall.ExitCode -notin 0, 3010) {
    throw "VirtIO driver MSI failed with exit code $($driverInstall.ExitCode)."
}

$agentInstall = Start-Process msiexec.exe `
    -ArgumentList '/i', 'D:\guest-agent\qemu-ga-x86_64.msi', '/qn', '/norestart' `
    -Wait -PassThru
if ($agentInstall.ExitCode -notin 0, 3010) {
    throw "QEMU guest-agent MSI failed with exit code $($agentInstall.ExitCode)."
}
```

#### Configure and verify the guest-agent services

```powershell
# Display the installed QEMU services. Current packages normally use the
# service names QEMU-GA and "QEMU Guest Agent VSS Provider".
Get-Service |
    Where-Object {
        $_.Name -match "QEMU" -or $_.DisplayName -match "QEMU"
    } |
    Format-Table Status, Name, DisplayName, StartType -AutoSize

# Configure and start the guest agent.
Set-Service -Name "QEMU-GA" -StartupType Automatic
Start-Service -Name "QEMU-GA"

# Configure and start the VSS provider if it is present in this package.
$qemuVss = Get-Service -Name "QEMU Guest Agent VSS Provider" `
    -ErrorAction SilentlyContinue
if ($qemuVss) {
    Set-Service -Name $qemuVss.Name -StartupType Automatic
    Start-Service -Name $qemuVss.Name
} else {
    Write-Warning "QEMU Guest Agent VSS Provider service was not found."
}

# VSS and the Microsoft Software Shadow Copy Provider are built into Windows.
# Do not change their default startup type; start them for this verification.
Start-Service -Name VSS
Start-Service -Name swprv

# Confirm service configuration and state.
Get-Service -Name "QEMU-GA", "VSS", "swprv" |
    Format-Table Status, Name, DisplayName, StartType -AutoSize
sc.exe qc "QEMU-GA"

# Confirm that Windows VSS writers are stable and report no errors.
vssadmin.exe list writers

# Confirm that the QEMU software provider is registered.
vssadmin.exe list providers
```

All listed VSS writers should report `State: [1] Stable` and `Last error: No
error`. `vssadmin list providers` should include `QEMU Guest Agent VSS
Provider`; it is a VSS provider, so it is not expected to appear in the writer
list.

Restart Windows if the installer returned `3010`, a newly installed driver is
pending activation, or the platform still does not detect the guest agent:

```powershell
Restart-Computer -Force
```

After the restart, repeat the service and `vssadmin.exe list writers` checks
above, then retry the KubeVirt/Harvester snapshot.

### Option 2: Manual Installation

```powershell
# Download QEMU Guest Agent from official sources
# Install with VSS support enabled
qemu-ga.exe -s install
```

### Option 3: Cloud-Init Integration

For automated deployments, include guest agent installation in your cloud-init configuration.

## VSS-Specific Troubleshooting

### Common VSS Issues and Solutions

#### 1. VSS Service Issues
```powershell
# Check if VSS services are running
sc query VSS
sc query SWPRV
sc query volsnap

# If any are stopped, start them:
sc start VSS
sc start SWPRV
```

#### 2. Insufficient Disk Space
VSS needs free space to create shadow copies:
```powershell
# Check free space on all drives (VSS needs at least 300MB on system drive)
Get-WmiObject -Class Win32_LogicalDisk | Where-Object {$_.DriveType -eq 3} | 
    Select-Object DeviceID, @{Name="FreeSpace(GB)";Expression={[math]::Round($_.FreeSpace/1GB,2)}}

# Clean up disk space if needed
cleanmgr
```

#### 3. VSS Writers Issues
```powershell
# List VSS writers and their state
vssadmin list writers

# Look for any writers in "Failed" state
# If you see failed writers, try restarting related services
```

#### 4. Registry Issues with VSS
```powershell
# Re-register VSS components
cd /d %windir%\system32
regsvr32 /s ole32.dll
regsvr32 /s oleaut32.dll
regsvr32 /s vss_ps.dll
```

#### 5. Volume Shadow Copy Storage
```powershell
# Check volume shadow copy settings
vssadmin list shadowstorage

# If no storage is allocated for shadow copies:
vssadmin add shadowstorage /for=C: /on=C: /maxsize=2GB
```

### Restart Services for VSS Issues
```powershell
# Restart VSS services
Restart-Service VSS
Restart-Service SWPRV

# Restart guest agent
Restart-Service "QEMU Guest Agent"
```

## Comprehensive Diagnostic Script

Save this PowerShell script and run it inside the Windows VM:

```powershell
Write-Host "=== QEMU Guest Agent & VSS Diagnostic ===" -ForegroundColor Green

# Check services
Write-Host "`n=== Service Status ===" -ForegroundColor Yellow
$services = @('QEMU Guest Agent', 'VSS', 'SWPRV', 'volsnap')
foreach ($svc in $services) {
    try {
        $service = Get-Service $svc -ErrorAction Stop
        Write-Host "$svc`: $($service.Status)" -ForegroundColor $(if($service.Status -eq 'Running'){'Green'}else{'Red'})
    } catch {
        Write-Host "$svc`: NOT FOUND" -ForegroundColor Red
    }
}

# Check free disk space
Write-Host "`n=== Disk Space Check ===" -ForegroundColor Yellow
Get-WmiObject -Class Win32_LogicalDisk | Where-Object {$_.DriveType -eq 3} | 
    ForEach-Object {
        $freeGB = [math]::Round($_.FreeSpace/1GB,2)
        $color = if($freeGB -gt 1){'Green'}else{'Red'}
        Write-Host "$($_.DeviceID) Free Space: $freeGB GB" -ForegroundColor $color
    }

# Check VSS writers
Write-Host "`n=== VSS Writers ===" -ForegroundColor Yellow
$writers = vssadmin list writers
$writers | Select-String -Pattern "Writer name|State" | ForEach-Object {
    if ($_ -match "State") {
        $color = if ($_ -match "Stable") {'Green'} else {'Red'}
        Write-Host $_.Line -ForegroundColor $color
    } else {
        Write-Host $_.Line -ForegroundColor Cyan
    }
}

# Check installation paths
Write-Host "`n=== Installation Check ===" -ForegroundColor Yellow
$paths = @(
    "C:\Program Files\Qemu-ga\qemu-ga.exe",
    "C:\Program Files\QEMU Guest Agent\qemu-ga.exe"
)
foreach ($path in $paths) {
    if (Test-Path $path) {
        Write-Host "Found: $path" -ForegroundColor Green
        try {
            $version = & $path --version 2>$null
            Write-Host "Version: $version" -ForegroundColor Green
        } catch {
            Write-Host "Could not get version" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Not Found: $path" -ForegroundColor Red
    }
}

# Check VSS shadow storage
Write-Host "`n=== VSS Shadow Storage ===" -ForegroundColor Yellow
vssadmin list shadowstorage

Write-Host "`n=== Diagnostic Complete ===" -ForegroundColor Green
```

## Quick Fixes Based on Diagnostic Results

### If Agent Shows "Disconnected":
- **Problem**: Guest agent not installed or not running
- **Solution**: Install virtio-win drivers package

### If Agent Connected but Freeze Fails:
- **Problem**: VSS not properly integrated or VSS services down
- **Solution**: Restart VSS services and guest agent

### If No VSS Writers Show QEMU:
- **Problem**: Guest agent installed without VSS support
- **Solution**: Reinstall with proper virtio-win package

### If VSS Writers Show "Failed" State:
- **Problem**: VSS writer corruption
- **Solution**: Re-register VSS components and restart services

## Prevention Measures

1. **Always use the virtio-win package** for guest agent installation
2. **Ensure adequate free space** (keep at least 15% free on system drives)
3. **Regularly update** QEMU Guest Agent via virtio-win updates
4. **Keep Windows updated** for VSS stability
5. **Monitor VSS health** with periodic checks

## Workarounds if VSS Cannot Be Fixed

### Option A: Snapshot with VM Powered Off
- Shut down the Windows VM
- Create the snapshot while VM is powered off
- This bypasses the need for filesystem freezing

### Option B: Use Application-Consistent Backups
- Use Windows built-in backup tools
- Use third-party backup solutions that handle VSS properly

### Option C: Disable VSS in Guest Agent (Not Recommended)
```cmd
# Stop QEMU Guest Agent
sc stop "QEMU Guest Agent"
# This will make snapshots less consistent but may work
```

## Related Error Messages

Watch for these error patterns in logs:
- `failed to add \\?\Volume{...}\ to snapshot set` - VSS volume addition failure
- `Guest agent not available for now` - Agent connectivity issue
- `fsfreeze is limited` - VSS resource constraints
- `Freezing VMI failed, please make sure guest agent and VSS are running` - KubeVirt-specific message

## References

- [KubeVirt Freeze Documentation](https://kubevirt.io/user-guide/operations/snapshot_restore_api/)
- [Fedora VirtIO Drivers](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/)
- [Windows VSS Documentation](https://docs.microsoft.com/en-us/windows/win32/vss/volume-shadow-copy-service-overview)

---
*Last Updated: July 2026*
