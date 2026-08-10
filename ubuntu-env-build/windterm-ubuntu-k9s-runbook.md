# WindTerm on Ubuntu: SSH, Kubernetes, and k9s Runbook

> Tested workflow and examples based on WindTerm **2.7.0** on Ubuntu.
>
> This document intentionally does **not** contain any SSH passwords. Do not store passwords in Initial Command fields or scripts. A password previously placed in an `sshpass -p` command should be rotated.

## 1. Overview

This runbook covers:

- Installing and starting WindTerm on Ubuntu
- Creating named SSH sessions
- Opening multiple sessions to the same server with different tab names
- Running `k9s` automatically with a session-specific kubeconfig
- Copying manifests from remote `k9s` to the local Ubuntu clipboard through WindTerm
- Moving between session tabs with keyboard shortcuts
- Customizing the previous/next-session shortcuts
- Organizing sessions into groups
- Connecting through a Jump Server
- Creating a local HTTPS tunnel through `buildserver`
- Backing up WindTerm profiles
- Troubleshooting common errors

The examples use:

```text
Local Ubuntu desktop
    |
    +-- buildserver: webber@100.108.77.122:22
            |
            +-- target node: rancher@10.115.252.33:22
            |
            +-- internal HTTPS service: 10.115.252.21:443
```

---

## 2. Install WindTerm 2.7.0 on Ubuntu

WindTerm for Linux is distributed as a portable archive.

```bash
tar -xzf WindTerm_2.7.0_Linux_Portable_x86_64.tar.gz
cd WindTerm_2.7.0
chmod +x WindTerm
./WindTerm
```

During the first launch, using your **Home Directory** as the profiles directory makes later upgrades and backups easier.

WindTerm stores its profile data under a `.wind` directory in the selected profiles directory.

---

## 3. Create the `buildserver` Session

Create a new SSH session with:

```text
Label: buildserver
Host: webber@100.108.77.122
Port: 22
Initial command: empty
Proxy type: None
```

The `Host` field can include the SSH username in `user@host` form.

Test the same connection outside WindTerm first:

```bash
ssh webber@100.108.77.122
```

SSH key authentication is strongly preferred.

### Configure passwordless SSH to buildserver

On the local Ubuntu desktop:

```bash
ssh-keygen -t ed25519
ssh-copy-id webber@100.108.77.122
```

Test it:

```bash
ssh webber@100.108.77.122
```

---

## 4. Create Multiple Named Sessions to the Same Server

For fixed tab names such as:

```text
107-155
lh-hrv
pvc
```

the most reliable approach is to create three separate saved sessions rather than opening the same `buildserver` session three times and manually renaming tabs.

Duplicate the `buildserver` session and assign a different **Label** to each copy:

```text
Label: 107-155
Host: webber@100.108.77.122
Port: 22
```

```text
Label: lh-hrv
Host: webber@100.108.77.122
Port: 22
```

```text
Label: pvc
Host: webber@100.108.77.122
Port: 22
```

The connection details can remain identical while each session has its own Initial Command and tab label.

---

## 5. Automatically Start k9s with a Specific Kubeconfig

In the session **Properties**, find the SSH option named:

```text
Execute command after authentication
```

WindTerm sends the configured text after SSH authentication. End the command with `\n` so that WindTerm also sends Enter.

### Recommended command

For the `107-155` session:

```text
KUBECONFIG=/home/webber/.kube/107-155.yaml k9s\n
```

For another cluster:

```text
KUBECONFIG=/home/webber/.kube/lh-hrv.yaml k9s\n
```

This form applies `KUBECONFIG` only to the `k9s` process.

### Keep KUBECONFIG after exiting k9s

Use this only when the variable should remain in the shell after `k9s` exits:

```text
export KUBECONFIG=/home/webber/.kube/107-155.yaml && k9s\n
```

### Add a short delay when the command runs too early

```text
sleep 1; KUBECONFIG=/home/webber/.kube/107-155.yaml k9s\n
```

### Optional tmux persistence

To reconnect to the same remote terminal state after an SSH interruption:

```text
tmux new-session -A -s 107-155 'KUBECONFIG=/home/webber/.kube/107-155.yaml k9s'\n
```

---

## 6. Copy k9s Manifests to the Local Clipboard over WindTerm SSH

### Why `xclip`, `xsel`, or `wl-clipboard` fails

The remote Ubuntu server reports:

```bash
echo "$XDG_SESSION_TYPE"
```

```text
tty
```

This means `k9s` is running on a headless remote shell rather than inside the remote server's graphical desktop session.

Installing these packages on the remote server generally does not give them access to the local Ubuntu desktop clipboard:

```text
xclip
xsel
wl-clipboard
```

The correct integration is **OSC52**. OSC52 lets a remote terminal application send clipboard content through the SSH terminal stream to the local terminal emulator.

WindTerm supports terminal clipboard operations, and current k9s releases support forcing OSC52 clipboard output.

### Test k9s with OSC52

Run on `buildserver`:

```bash
K9S_CLIPBOARD=osc52 k9s
```

Then use the copy action shown in the current k9s view. The copied manifest should appear in the clipboard of the Ubuntu desktop running WindTerm.

### Recommended Initial Command

Combine the kubeconfig and clipboard settings:

```text
K9S_CLIPBOARD=osc52 K9S_OSC52_MAX=1000000 KUBECONFIG=/home/webber/.kube/107-155.yaml k9s\n
```

For `lh-hrv`:

```text
K9S_CLIPBOARD=osc52 K9S_OSC52_MAX=1000000 KUBECONFIG=/home/webber/.kube/lh-hrv.yaml k9s\n
```

`K9S_OSC52_MAX` raises the maximum OSC52 payload for large Kubernetes manifests.

### Make OSC52 the default on the remote server

Add the variables to `~/.bashrc`:

```bash
cat >> ~/.bashrc <<'EOF'
export K9S_CLIPBOARD=osc52
export K9S_OSC52_MAX=1000000
EOF
```

Reload the shell:

```bash
source ~/.bashrc
```

The Initial Command can then be simplified to:

```text
KUBECONFIG=/home/webber/.kube/107-155.yaml k9s\n
```

### Test OSC52 without k9s

Run this on the remote server:

```bash
printf '\033]52;c;%s\a' "$(printf 'osc52-test' | base64 -w 0)"
```

Then paste into a local Ubuntu editor.

Expected clipboard content:

```text
osc52-test
```

If this works but k9s still shows:

```text
😡 exit status 1
```

upgrade k9s to a release that supports the clipboard environment variables.

### Upgrade k9s on Ubuntu

```bash
wget https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb
sudo apt install ./k9s_linux_amd64.deb
rm k9s_linux_amd64.deb
```

Verify:

```bash
k9s version
```

### OSC52 and tmux

When `k9s` runs inside tmux and copying does not reach WindTerm, add this to `~/.tmux.conf`:

```tmux
set -g set-clipboard on
```

Reload tmux:

```bash
tmux source-file ~/.tmux.conf
```

A new tmux server may be required before the setting fully applies.

---

## 7. Switch Between Session Tabs

WindTerm's default previous/next session shortcuts are:

```text
Alt + [    Previous session/view
Alt + ]    Next session/view
```

These actions are internally named:

```text
Window.ActivatePreviousView
Window.ActivateNextView
```

Direct session selection may also be available through numbered tab/session shortcuts, depending on the active WindTerm mode and configuration.

---

## 8. Change Previous/Next Session Shortcuts

WindTerm key mappings are stored in:

```text
global/wind.keymaps
```

First find the active file:

```bash
find ~ /opt -type f -path '*/global/wind.keymaps' 2>/dev/null
```

Close WindTerm before editing the file.

Back it up:

```bash
cp /path/to/global/wind.keymaps \
   /path/to/global/wind.keymaps.bak
```

To use **Ctrl+Right Arrow** and **Ctrl+Left Arrow**:

```json
{
    "keys": "<Ctrl+Right>",
    "modes": "remote",
    "action": "Window.ActivateNextView"
},
{
    "keys": "<Ctrl+Left>",
    "modes": "remote",
    "action": "Window.ActivatePreviousView"
},
```

Restart WindTerm after saving.

### Important conflict

In Bash, Zsh, and other shells:

```text
Ctrl+Left
Ctrl+Right
```

normally move the cursor by one word. Mapping them in WindTerm remote mode means WindTerm consumes the keys before the remote shell receives them.

Search the keymap file for duplicate bindings:

```bash
grep -nE '<Ctrl\+(Left|Right)>' /path/to/global/wind.keymaps
```

---

## 9. Organize Sessions in the Session Pane

A useful layout is:

```text
Kubernetes
├── 107-155
├── lh-hrv
└── pvc

Infrastructure
├── buildserver
└── 107-155-node
```

WindTerm 2.7.0 supports moving session-tree nodes by drag-and-drop and through the **Move To...** context-menu action.

Depending on the exact Session Pane context, group creation may appear as **Group**, or a group may be created while organizing selected sessions. After a group exists, sessions can be dragged into it or moved with **Move To...**.

Use distinct saved session labels to preserve useful tab names.

---

## 10. Jump Server Configuration

### Goal

Connect directly from the local WindTerm UI to:

```text
rancher@10.115.252.33
```

through:

```text
webber@100.108.77.122
```

without running `sshpass` in an Initial Command.

### Equivalent OpenSSH test

Test the route outside WindTerm:

```bash
ssh -J webber@100.108.77.122 rancher@10.115.252.33
```

If this command fails, fix the SSH route or authentication before troubleshooting WindTerm.

### Verify connectivity from buildserver

```bash
ssh webber@100.108.77.122
nc -vz 10.115.252.33 22
ssh rancher@10.115.252.33
```

Interpret common errors:

```text
Connection timed out
```

The route or firewall from buildserver to the target is not working.

```text
Connection refused
```

The target is reachable, but SSH is not listening on port 22.

```text
Permission denied
```

The network path works, but target authentication failed.

### WindTerm 2.7.0 sessions

#### `buildserver`

```text
Label: buildserver
Host: webber@100.108.77.122
Port: 22
Initial command: empty
Proxy type: None
```

#### `107`

```text
Label: 107
Host: rancher@10.115.252.33
Port: 22
Initial command: empty
Proxy Type: Jump Servers
Jump Server 1: buildserver
```

Be careful not to type:

```text
rancher@0.115.252.33
```

The correct address begins with `10`.

### Remove insecure Initial Commands

Do not use:

```text
sshpass -p 'PASSWORD' ssh rancher@10.115.252.33
```

Problems with this pattern:

- The password is stored as plain text in the WindTerm profile.
- The password can appear in process arguments.
- The password may be included in profile backups.
- The first SSH connection is a shell session rather than a native proxy connection.

### Preferred authentication: SSH key through ProxyJump

From the local Ubuntu desktop:

```bash
ssh-copy-id \
  -o ProxyJump=webber@100.108.77.122 \
  rancher@10.115.252.33
```

Test:

```bash
ssh -J webber@100.108.77.122 rancher@10.115.252.33
```

After key authentication works, configure the corresponding private key in the WindTerm target session if WindTerm does not automatically use the expected key or SSH agent.

---

## 11. Access an Internal HTTPS Service Through buildserver

### Goal

Access:

```text
10.115.252.21:443
```

from the local Ubuntu desktop through `buildserver`.

### Recommended local port-forward command

Run on the local Ubuntu desktop:

```bash
ssh -NT \
  -L 127.0.0.1:8443:10.115.252.21:443 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  webber@100.108.77.122
```

Keep this terminal open and browse to:

```text
https://127.0.0.1:8443
```

Test with:

```bash
curl -vk https://127.0.0.1:8443
```

### Background mode

After the foreground command works:

```bash
ssh -fNT \
  -L 127.0.0.1:8443:10.115.252.21:443 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  webber@100.108.77.122
```

### Verify the local listener

```bash
ss -ltnp | grep ':8443'
```

Expected:

```text
LISTEN ... 127.0.0.1:8443
```

### Check the service from buildserver

```bash
ssh webber@100.108.77.122 \
  'curl -kIs --connect-timeout 5 https://10.115.252.21 | head'
```

If this fails, the issue is between `buildserver` and `10.115.252.21:443`, not the local tunnel.

### HTTPS certificate warning

Accessing an internal service through:

```text
https://127.0.0.1:8443
```

can cause a certificate-name mismatch because the certificate was probably issued for the internal service's DNS name rather than `127.0.0.1`.

Use the certificate's correct hostname when possible and map that hostname to `127.0.0.1` in the local `/etc/hosts`.

---

## 12. Back Up and Restore WindTerm

With WindTerm closed, back up the profile directory:

```bash
cp -a ~/.wind ~/.wind.backup
```

A dated backup is safer:

```bash
cp -a ~/.wind "$HOME/.wind.backup.$(date +%Y%m%d-%H%M%S)"
```

The `.wind` directory contains saved sessions and application configuration. WindTerm documents this profile directory as cross-platform.

Never share a `.wind` backup without reviewing it because it may contain saved authentication information.

---

## 13. Recommended Final Session Design

```text
Kubernetes
├── 107-155
│   └── K9S_CLIPBOARD=osc52 K9S_OSC52_MAX=1000000
│       KUBECONFIG=/home/webber/.kube/107-155.yaml k9s
│
├── lh-hrv
│   └── K9S_CLIPBOARD=osc52 K9S_OSC52_MAX=1000000
│       KUBECONFIG=/home/webber/.kube/lh-hrv.yaml k9s
│
└── pvc
    └── K9S_CLIPBOARD=osc52 K9S_OSC52_MAX=1000000
        KUBECONFIG=/home/webber/.kube/107-155.yaml
        k9s --namespace longhorn-system

Infrastructure
├── buildserver
│   └── webber@100.108.77.122
│
└── 107-node
    ├── rancher@10.115.252.33
    └── Jump Server 1: buildserver
```

For the actual WindTerm Initial Command, keep each command on one line and terminate it with `\n`, for example:

```text
K9S_CLIPBOARD=osc52 K9S_OSC52_MAX=1000000 KUBECONFIG=/home/webber/.kube/107-155.yaml k9s\n
```

---

## 14. Quick Troubleshooting Checklist

### WindTerm Initial Command appears but does not execute

Ensure it ends with:

```text
\n
```

### k9s copy shows `😡 exit status 1`

1. Confirm the remote session is a TTY:

   ```bash
   echo "$XDG_SESSION_TYPE"
   ```

2. Force OSC52:

   ```bash
   K9S_CLIPBOARD=osc52 k9s
   ```

3. Test OSC52 directly:

   ```bash
   printf '\033]52;c;%s\a' "$(printf 'osc52-test' | base64 -w 0)"
   ```

4. Upgrade k9s.
5. Increase the payload limit:

   ```bash
   export K9S_OSC52_MAX=1000000
   ```

6. If tmux is involved, enable:

   ```tmux
   set -g set-clipboard on
   ```

### Jump Server does not work

1. Check that the target address is exactly:

   ```text
   rancher@10.115.252.33
   ```

2. Test:

   ```bash
   ssh -J webber@100.108.77.122 rancher@10.115.252.33
   ```

3. Test port 22 from buildserver:

   ```bash
   ssh webber@100.108.77.122 'nc -vz 10.115.252.33 22'
   ```

4. Keep both sessions' Initial Command fields empty while testing.

### Local port 8443 is already in use

```bash
ss -ltnp | grep ':8443'
```

Choose another local port, for example:

```bash
-L 127.0.0.1:9443:10.115.252.21:443
```

### Custom shortcuts do not work

- Close WindTerm before editing `wind.keymaps`.
- Search for duplicate key bindings.
- Check JSON commas and braces.
- Restart WindTerm completely.

---

## References

- [WindTerm GitHub repository](https://github.com/kingToolbox/WindTerm)
- [WindTerm 2.7.0 release](https://github.com/kingToolbox/WindTerm/releases/tag/2.7.0)
- [WindTerm Jump Server documentation](https://kingtoolbox.github.io/2021/03/11/proxy-jump-server/)
- [WindTerm port-forwarding documentation](https://kingtoolbox.github.io/2020/07/21/port_forwarding/)
- [WindTerm remote and local keyboard modes](https://kingtoolbox.github.io/2020/06/21/keyboard-modes/)
- [k9s GitHub repository and clipboard environment variables](https://github.com/derailed/k9s)
- [k9s documentation](https://k9scli.io/)
