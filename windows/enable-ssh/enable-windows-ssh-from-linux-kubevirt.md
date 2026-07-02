# Enable SSH on a Windows KubeVirt VM and Connect from Linux

This note summarizes the steps used to enable OpenSSH Server on a Windows VM running on Harvester/KubeVirt, then SSH into it from a Linux machine.

## Environment

```text
Linux client IP:   10.115.54.34
Windows VM IP:    10.115.7.142
Windows VM name:  windows-vm
Namespace:        default
Harvester/KubeVirt VM running on node: hp-107-tink-system
```

The Windows VM is a KubeVirt VM on Harvester. Direct LAN access is attempted first. If direct access has issues, `virtctl port-forward` can be used as an alternative tunnel through KubeVirt.

## 1. Confirm the Windows VM is running

From the Linux machine with kubeconfig access:

```bash
kubectl get vmi -A -o wide
```

Example output:

```text
NAMESPACE   NAME                              AGE   PHASE     IP             NODENAME             READY   LIVE-MIGRATABLE   PAUSED
default     cluster-107-155-1-c-4chmp-wsdgx   21d   Running   10.115.5.31    hp-155-tink-system   True    True
default     cluster-107-155-1-w-wfdkq-ccdfx   21d   Running   10.115.4.144   hp-107-tink-system   True    True
default     windows-vm                        78m   Running                  hp-107-tink-system   True    True
```

Note: The `windows-vm` VMI did not show an IP in this output, but the Windows guest itself had IP `10.115.7.142`.

## 2. Enable OpenSSH Server inside Windows

Open PowerShell as Administrator inside the Windows VM.

Install OpenSSH Server:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

Start the SSH service:

```powershell
Start-Service sshd
```

Enable SSH service at boot:

```powershell
Set-Service sshd -StartupType Automatic
```

Check the service status:

```powershell
Get-Service sshd
```

If needed, run these again to ensure the service is running and enabled:

```powershell
Start-Service sshd
Set-Service sshd -StartupType Automatic
```

## 3. Allow inbound SSH in Windows Firewall

Run this in PowerShell as Administrator:

```powershell
New-NetFirewallRule -DisplayName "Allow SSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow
```

This is the one-line version of the multiline command:

```powershell
New-NetFirewallRule `
  -DisplayName "Allow SSH" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 22 `
  -Action Allow
```

## 4. SSH directly from Linux to Windows

From Linux:

```bash
ssh Administrator@10.115.7.142
```

For another Windows user, replace `Administrator` with the actual Windows username:

```bash
ssh <windows-user>@10.115.7.142
```

If Windows local account naming causes issues, try one of these forms:

```bash
ssh '.\Administrator'@10.115.7.142
ssh 'WINDOWS-HOSTNAME\Administrator'@10.115.7.142
```

## 5. Optional: use `virtctl port-forward` instead of direct LAN SSH

If direct SSH to `10.115.7.142` does not work, but Linux can reach the Harvester/Kubernetes API, use `virtctl port-forward`.

In terminal 1, start the tunnel:

```bash
virtctl port-forward vm/windows-vm/default 2222:22
```

Expected output:

```text
{"component":"portforward","level":"info","msg":"forwarding tcp 127.0.0.1:2222 to 22","pos":"portforwarder.go:22","timestamp":"2026-07-02T09:33:25.393836Z"}
```

This command does not return because it keeps the tunnel open. Keep terminal 1 running.

In terminal 2, SSH through the tunnel:

```bash
ssh Administrator@127.0.0.1 -p 2222
```

or:

```bash
ssh Administrator@localhost -p 2222
```

To stop the tunnel, go back to terminal 1 and press:

```text
Ctrl + C
```

## 6. Useful troubleshooting commands

Test whether Windows TCP port 22 is reachable from Linux:

```bash
nc -vz 10.115.7.142 22
```

Run SSH with verbose logs:

```bash
ssh -vvv Administrator@10.115.7.142
```

Check whether SSH is listening inside Windows:

```powershell
Get-Service sshd
Get-NetTCPConnection -LocalPort 22 -State Listen
netstat -ano | findstr :22
```

Expected listening state should show something like:

```text
0.0.0.0:22    LISTENING
```

## 7. Common result meanings

### `Connection refused`

The Windows VM is reachable, but port 22 is not listening. Check `sshd` service and whether OpenSSH Server is installed.

### `Connection timed out`

The Linux machine cannot reach Windows TCP/22. This may be caused by firewall, routing, VM network configuration, or LAN reachability.

### `Permission denied`

Network and SSH service are working, but authentication failed. Check username, password, key, or Windows account format.

## Summary

The main Windows-side commands applied were:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service sshd -StartupType Automatic
Get-Service sshd
New-NetFirewallRule -DisplayName "Allow SSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow
```

Then direct SSH from Linux:

```bash
ssh Administrator@10.115.7.142
```

Alternative via KubeVirt:

```bash
virtctl port-forward vm/windows-vm/default 2222:22
ssh Administrator@127.0.0.1 -p 2222
```
