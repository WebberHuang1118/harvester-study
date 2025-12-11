# Harvester VM SSH Access Guide

This guide provides step-by-step instructions for enabling SSH access to virtual machines running on Harvester, covering both SUSE Linux Micro and Windows Server 2022.

## Table of Contents

- [SUSE Linux Micro SSH Setup](#suse-linux-micro-ssh-setup)
- [Windows Server 2022 SSH Setup](#windows-server-2022-ssh-setup)
- [Exposing SSH Service via NodePort](#exposing-ssh-service-via-nodeport)
- [Connecting to VMs](#connecting-to-vms)
- [Troubleshooting](#troubleshooting)

## SUSE Linux Micro SSH Setup

### 1. Install and Enable SSH Server

SUSE Linux Micro uses transactional updates for system modifications:

```bash
# Install OpenSSH server
sudo transactional-update pkg install openssh

# Reboot to apply the transactional update
sudo reboot

# After reboot, enable and start the SSH service
sudo systemctl enable sshd
sudo systemctl start sshd
```

### 2. Configure SSH Authentication

Edit the SSH daemon configuration to enable password authentication:

```bash
sudo vi /etc/ssh/sshd_config
```

Add or modify the following lines:

```
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
```

### 3. Restart SSH Service

Apply the configuration changes:

```bash
sudo systemctl restart sshd
```

### 4. Verify SSH Status

Confirm that SSH is running properly:

```bash
sudo systemctl status sshd
```

## Windows Server 2022 SSH Setup

### 1. Install OpenSSH Server

Open PowerShell as Administrator and run:

```powershell
# Install OpenSSH Server feature
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

### 2. Configure SSH Service

Start the SSH service and set it to start automatically:

```powershell
# Start the SSH service
Start-Service sshd

# Set SSH service to start automatically on boot
Set-Service -Name sshd -StartupType Automatic

# Verify the service is running
Get-Service sshd
```

### 3. Configure Windows Firewall (if needed)

```powershell
# Allow SSH through Windows Firewall
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

### 4. Create SSH User Account

Create a dedicated user for SSH access:

```powershell
# Create a new user (replace 'YourPasswordHere' with a secure password)
net user sshuser YourPasswordHere /add

# Add the user to the Remote Desktop Users group (optional)
net localgroup "Remote Desktop Users" sshuser /add
```

## Exposing SSH Service via NodePort

To access the VM's SSH service from outside the Kubernetes cluster, expose it using a NodePort service:

```bash
# Expose the VM's SSH port (22) via NodePort on port 2222
virtctl expose vmi <your-vm-name> --port=2222 --target-port=22 --type=NodePort --name=<your-vm-name>-ssh

# Get the assigned NodePort
kubectl get svc <your-vm-name>-ssh
```

**Example:**
```bash
virtctl expose vmi ssh-vmi --port=2222 --target-port=22 --type=NodePort --name=ssh-vmi-service
```

## Connecting to VMs

### Get Connection Details

1. Find the NodePort assigned to your service:
   ```bash
   kubectl get svc <your-vm-name>-ssh -o wide
   ```

2. Get the external IP of any Kubernetes node:
   ```bash
   kubectl get nodes -o wide
   ```

### SSH Connection

Connect using any SSH client from a host that can reach the Kubernetes cluster nodes:

**For SUSE Linux Micro:**
```bash
ssh <username>@<node-ip> -p <nodeport>
```

**For Windows Server 2022:**
```bash
ssh sshuser@<node-ip> -p <nodeport>
```

**Example:**
```bash
ssh sshuser@192.168.1.100 -p 32022
```

## Troubleshooting

### Common Issues

1. **Connection refused:**
   - Verify SSH service is running: `systemctl status sshd` (Linux) or `Get-Service sshd` (Windows)
   - Check if the correct port is exposed in the NodePort service

2. **Authentication failed:**
   - Ensure password authentication is enabled in SSH configuration
   - Verify user credentials are correct

3. **Cannot reach NodePort:**
   - Confirm the NodePort service is created: `kubectl get svc`
   - Ensure the Kubernetes node IP is accessible from your client
   - Check firewall rules on both the node and VM

### Useful Commands

```bash
# Check VM status
kubectl get vmi

# View NodePort services
kubectl get svc --field-selector spec.type=NodePort

# Check VM logs
kubectl logs <vm-pod-name>

# Delete NodePort service
kubectl delete svc <service-name>
```

## Security Considerations

- Use strong passwords or SSH keys for authentication
- Consider changing the default SSH port (22) for additional security
- Regularly update the guest operating systems
- Monitor SSH access logs for suspicious activity
- Use firewall rules to restrict SSH access to trusted networks only

---

**Note:** This guide assumes you have proper access to the Harvester cluster and necessary permissions to create services and expose VM ports.