# VS Code Remote-SSH + Codex Troubleshooting Runbook

This runbook covers troubleshooting when:

- VS Code connects to an Ubuntu server through Remote-SSH.
- Opening a remote repository becomes stuck or unresponsive.
- Multiple VS Code Server processes appear on the remote server.
- The OpenAI ChatGPT/Codex extension is installed on the remote host.
- More than one `Stable-*` VS Code Server directory or process is visible.

> **Important:** Commands are explicitly marked as either **LOCAL** or **REMOTE**.
>
> - **LOCAL** = your Ubuntu desktop where the VS Code GUI runs.
> - **REMOTE** = the Ubuntu server reached through SSH.
>
> Run remote cleanup commands from a separate SSH client such as WindTerm, not from the VS Code integrated terminal.

---

## 1. Environment Used in This Investigation

### LOCAL — Ubuntu desktop

```bash
code --version
```

Observed:

```text
1.129.1
8a7abeba6e03ea3af87bfbce9a1b7e48fed567b8
x64
```

Therefore, the normal Remote-SSH server matching this local VS Code installation should use commit:

```text
8a7abeba6e03ea3af87bfbce9a1b7e48fed567b8
```

### REMOTE — Ubuntu server

The remote VS Code files are located under:

```text
/home/webber/.vscode-server/
```

Typical directories include:

```text
~/.vscode-server/cli/
~/.vscode-server/data/
~/.vscode-server/extensions/
~/.vscode-server/cli/servers/Stable-*/
~/.vscode-server/code-*
```

Multiple installed `Stable-*` or `code-*` versions can exist. Their presence alone does not prove that something is broken.

---

## 2. First Check: Inspect Remote VS Code Processes

### REMOTE

```bash
pgrep -af '/home/webber/\.vscode-server/'
```

This is safer and more focused than:

```bash
ps -ef | grep code
```

The broad `grep code` command may also match unrelated processes containing the word `code`.

### Common Remote-SSH process types

A normal Remote-SSH workspace session may include:

```text
code-<commit> ... agent host
Stable-<commit>/server/bin/code-server
Stable-<commit>/server/out/server-main.js
bootstrap-fork --type=extensionHost
bootstrap-fork --type=fileWatcher
bootstrap-fork --type=ptyHost
```

Typical meanings:

| Process | Purpose |
|---|---|
| `server-main.js` | Main VS Code remote server |
| `extensionHost` | Runs extensions installed on the remote host |
| `fileWatcher` | Watches repository files for changes |
| `ptyHost` | Manages integrated terminals |
| `agent host` | Manages newer agent-related functionality |
| `codex ... app-server` | OpenAI ChatGPT/Codex remote process |

Several `extensionHost` processes may be normal, especially when multiple VS Code windows, extension environments, or agent sessions are active.

---

## 3. How to Identify the Main Remote-SSH Server

Compare the commit from the local command:

### LOCAL

```bash
code --version
```

With remote process paths:

### REMOTE

```bash
pgrep -af '/home/webber/\.vscode-server/'
```

For this environment:

```text
LOCAL commit:
8a7abeba6e03ea3af87bfbce9a1b7e48fed567b8
```

The main Remote-SSH process was identified by both:

```text
Stable-8a7abeba.../server-main.js
```

and:

```text
--connection-token=remotessh
```

Therefore, `Stable-8a7abeba...` is the main Remote-SSH workspace server.

---

## 4. Why Another `Stable-*` Version May Appear

The following process pattern was also observed:

```text
Stable-1b6a188.../server-main.js
  --agent-host-path ...
  --without-connection-token
```

It was associated with:

```text
bootstrap-fork --type=agentHost
```

and:

```text
~/.vscode-server/extensions/openai.chatgpt-*/bin/linux-x86_64/codex ... app-server
```

This strongly suggests that `Stable-1b6a188...` is a separate agent-host runtime used by VS Code agent or Codex functionality.

Therefore:

```text
Stable-8a7abeba... = main VS Code 1.129.1 Remote-SSH workspace server
Stable-1b6a188...  = separate agent-host runtime associated with agent/Codex activity
```

The second build is not automatically a stale or conflicting Remote-SSH server.

Do not delete `Stable-1b6a188...` solely because it does not match the local VS Code commit.

---

## 5. Safe Full Reset of Remote VS Code Processes

Use this when opening the remote repository is completely stuck.

### Step 1 — Close all VS Code windows

### LOCAL

Close every VS Code window connected to the remote server.

Then check whether local VS Code processes remain:

```bash
pgrep -af '[c]ode'
```

If necessary, gracefully stop local VS Code:

```bash
pkill -TERM -f '/usr/share/code/code'
sleep 3
pgrep -af '[c]ode'
```

Depending on how VS Code was installed, its path might instead contain:

```text
/snap/code/
/opt/visual-studio-code/
```

Avoid killing unrelated programs without first reviewing the process list.

### Step 2 — Stop remote VS Code processes

Run this through WindTerm or another independent SSH session.

### REMOTE

First inspect the matching processes:

```bash
pgrep -af '/home/webber/\.vscode-server/'
```

Gracefully terminate them:

```bash
pkill -TERM -u "$USER" -f '/home/webber/\.vscode-server/'
sleep 3
```

Check for survivors:

```bash
pgrep -af '/home/webber/\.vscode-server/'
```

If processes remain and will not exit:

```bash
pkill -KILL -u "$USER" -f '/home/webber/\.vscode-server/'
```

### What this affects

This terminates:

- Remote-SSH sessions
- VS Code integrated terminals
- Remote extension hosts
- File watchers
- Debug sessions
- Running VS Code tasks
- ChatGPT/Codex remote processes

It does **not** delete:

- Git repositories
- Source files
- Commits
- Branches
- Uncommitted file contents already saved to disk

Unsaved editor buffers may be lost, so close VS Code cleanly first whenever possible.

### Step 3 — Reconnect using only one window

### LOCAL

Open one VS Code window and connect to the remote host.

Do not reopen many Remote-SSH windows simultaneously during the first test.

---

## 6. Preferred Built-In VS Code Reset Command

Instead of manually killing processes, VS Code provides:

### LOCAL — VS Code Command Palette

```text
Remote-SSH: Kill VS Code Server on Host...
```

Select the affected remote host.

This is the preferred first reset method when the VS Code GUI is still responsive.

---

## 7. Test Whether an Extension Is Causing the Hang

If Remote-SSH connects but opening the repository remains stuck, test without extensions.

### LOCAL — VS Code Command Palette

Run:

```text
Developer: Reload With Extensions Disabled
```

Then reopen the remote repository.

### Interpretation

- Repository opens normally:
  - Remote-SSH is probably healthy.
  - A local or remote extension is likely causing the problem.

- Repository remains stuck:
  - Continue checking server logs, repository size, filesystem performance, Git operations, or remote system resources.

---

## 8. Test the OpenAI ChatGPT/Codex Extension Specifically

Because the remote process list includes:

```text
~/.vscode-server/extensions/openai.chatgpt-*/.../codex ... app-server
```

Codex should be tested independently.

### Option A — Disable the extension in VS Code

### LOCAL — VS Code Extensions view

Locate the ChatGPT/Codex extension and choose one of:

```text
Disable (Workspace)
```

or:

```text
Disable (SSH: <remote-host>)
```

Then reload the remote window.

### Option B — Stop only Codex and the separate agent host

Run from WindTerm.

### REMOTE

Stop the Codex application server:

```bash
pkill -TERM -u "$USER" \
  -f '/home/webber/\.vscode-server/extensions/openai\.chatgpt-.*/codex .*app-server'
```

Stop the separate observed agent-host runtime:

```bash
pkill -TERM -u "$USER" \
  -f '/home/webber/\.vscode-server/cli/servers/Stable-1b6a188127eeaf9194f945eb6eb89a657e93c54c/'
```

Then inspect what remains:

```bash
pgrep -af '/home/webber/\.vscode-server/'
```

Expected result during this test:

- Main `Stable-8a7abeba...` Remote-SSH processes remain.
- Codex and `Stable-1b6a188...` agent-host processes disappear.

Then test whether the repository becomes responsive.

### Interpretation

If responsiveness returns after stopping Codex or disabling the extension, the likely problem is in the Codex/agent-host path rather than the main Remote-SSH server.

---

## 9. When to Remove a Remote VS Code Server Installation

Only remove a server directory when there is evidence that its installation is damaged, repeatedly fails to start, or is no longer needed.

Possible symptoms include:

- Missing Node.js modules
- Server repeatedly exits immediately
- Remote-SSH logs show an incomplete installation
- Reinstall loops
- The matching `server-main.js` cannot start
- A partially extracted `Stable-*` directory exists

### Before deleting anything

### LOCAL

Confirm the currently installed VS Code commit:

```bash
code --version
```

### REMOTE

List installed servers:

```bash
ls -lah ~/.vscode-server/cli/servers/
ls -lah ~/.vscode-server/code-*
```

### Remove only a specific damaged version

Example:

```bash
rm -rf ~/.vscode-server/cli/servers/Stable-<commit>
rm -f ~/.vscode-server/code-<commit>
```

Do not blindly delete every `Stable-*` version when Codex or agent functionality may legitimately use another runtime.

### Full reinstall as a last resort

With all local VS Code windows closed:

### REMOTE

```bash
pkill -TERM -u "$USER" -f '/home/webber/\.vscode-server/'
sleep 3
```

Optionally preserve extensions while resetting only server binaries:

```bash
mv ~/.vscode-server/cli/servers \
   ~/.vscode-server/cli/servers.backup.$(date +%Y%m%d-%H%M%S)
```

Then reconnect from one local VS Code window.

VS Code should download the necessary remote server again.

Avoid deleting the entire `.vscode-server` directory unless necessary, because it may remove remote extensions, cached data, logs, and user state.

---

## 10. Check Remote Resource Pressure

A repository may appear stuck because the remote system is overloaded.

### REMOTE

Check memory and swap:

```bash
free -h
```

Check CPU and load:

```bash
uptime
top
```

Or, if installed:

```bash
htop
```

Check disk space:

```bash
df -h
```

Check inode availability:

```bash
df -i
```

Check `.vscode-server` size:

```bash
du -sh ~/.vscode-server
du -sh ~/.vscode-server/* 2>/dev/null | sort -h
```

Check repository size:

```bash
du -sh ~/networkfs-manager
```

Check whether the filesystem is slow or remote-mounted:

```bash
findmnt -T ~/networkfs-manager
```

---

## 11. Check for Expensive Repository Operations

File watching, Git status, and language servers may be expensive in a large repository.

### REMOTE

Count repository files:

```bash
find ~/networkfs-manager -type f | wc -l
```

Check Git status timing:

```bash
cd ~/networkfs-manager
time git status
```

Check for very large directories:

```bash
du -h --max-depth=2 ~/networkfs-manager | sort -h | tail -30
```

Common problematic directories include:

```text
node_modules/
vendor/
build/
dist/
coverage/
.cache/
.generated/
```

These directories can be excluded from VS Code file watching and search when appropriate.

Example workspace settings:

```json
{
  "files.watcherExclude": {
    "**/.git/objects/**": true,
    "**/.git/subtree-cache/**": true,
    "**/node_modules/**": true,
    "**/vendor/**": true,
    "**/build/**": true,
    "**/dist/**": true
  },
  "search.exclude": {
    "**/node_modules": true,
    "**/vendor": true,
    "**/build": true,
    "**/dist": true
  }
}
```

Only add exclusions that are appropriate for the repository.

---

## 12. Inspect VS Code Remote Logs

### LOCAL — VS Code

Open:

```text
View → Output
```

Then select:

```text
Remote - SSH
```

Also check:

```text
Log (Remote Server)
Log (Extension Host)
```

### REMOTE

List recent log directories:

```bash
ls -lt ~/.vscode-server/data/logs/ | head
```

Inspect the newest logs:

```bash
LATEST_LOG_DIR="$(ls -1dt ~/.vscode-server/data/logs/* | head -1)"
echo "$LATEST_LOG_DIR"
find "$LATEST_LOG_DIR" -maxdepth 2 -type f -print
```

Search for errors:

```bash
grep -RniE \
  'error|failed|exception|timeout|cannot find module|ENOMEM|ENOSPC' \
  "$LATEST_LOG_DIR"
```

View recent log lines:

```bash
find "$LATEST_LOG_DIR" -type f -print0 |
  xargs -0 -I{} sh -c 'echo "===== {} ====="; tail -n 100 "{}"'
```

---

## 13. Inspect Codex Processes and Logs

### REMOTE

Find Codex processes:

```bash
pgrep -af '/openai\.chatgpt-.*/codex'
```

Find the installed extension:

```bash
ls -1d ~/.vscode-server/extensions/openai.chatgpt-* 2>/dev/null
```

Inspect extension size:

```bash
du -sh ~/.vscode-server/extensions/openai.chatgpt-* 2>/dev/null
```

Locate recent Codex-related log messages:

```bash
LATEST_LOG_DIR="$(ls -1dt ~/.vscode-server/data/logs/* | head -1)"

grep -RniE \
  'codex|openai|chatgpt|agentHost|agent host|error|failed|timeout' \
  "$LATEST_LOG_DIR"
```

---

## 14. Useful Process-Tree Commands

### REMOTE

Show the full process tree:

```bash
ps -ef --forest | grep -E '[v]scode-server|[c]odex|[s]erver-main|[e]xtensionHost'
```

If `pstree` is installed:

```bash
pstree -ap "$USER" | grep -E 'vscode|code-server|codex|server-main'
```

Show process parent-child relationships with selected fields:

```bash
ps -eo user,pid,ppid,lstart,etime,cmd |
  grep -E '[v]scode-server|[c]odex'
```

This helps distinguish:

- the main Remote-SSH server;
- workspace extension hosts;
- Codex;
- a separately launched agent host;
- truly stale processes.

---

## 15. Commands to Avoid

### Avoid an overly broad kill

Do not immediately run:

```bash
pkill -f code
```

It can match unrelated commands or applications containing the word `code`.

Prefer:

```bash
pkill -TERM -u "$USER" -f '/home/webber/\.vscode-server/'
```

### Avoid deleting the complete remote state first

Do not start with:

```bash
rm -rf ~/.vscode-server
```

This removes more than the server binary and may destroy useful logs and remote extension installations.

### Avoid treating every different commit as a conflict

A different `Stable-*` commit can represent:

- an older cached server;
- another local VS Code client version;
- a separate agent-host runtime;
- Codex or another extension-related runtime.

Use process arguments and parent-child relationships to identify its purpose before deleting it.

---

## 16. Security Note About Process Output

VS Code processes may expose command-line values such as:

```text
--connection-token=...
--agent-host-bridge-connection-token=...
```

These tokens are usually temporary, but process output containing them should not be posted publicly without redaction.

Before sharing logs, replace them with:

```text
--connection-token=<redacted>
--agent-host-bridge-connection-token=<redacted>
```

Also redact:

- usernames, when necessary;
- hostnames and IP addresses;
- repository secrets;
- proxy credentials;
- access tokens;
- private Git URLs.

---

## 17. Recommended Troubleshooting Decision Tree

### A. Remote repository is stuck

1. **LOCAL:** Close all VS Code windows.
2. **REMOTE:** Kill all `.vscode-server` processes.
3. **LOCAL:** Open one VS Code window.
4. Reconnect and test.

### B. It still hangs

1. **LOCAL:** Run `Developer: Reload With Extensions Disabled`.
2. Test the repository again.

### C. It works with extensions disabled

1. Re-enable extensions gradually.
2. Test ChatGPT/Codex first.
3. Disable Codex for the remote workspace.
4. Optionally kill only Codex and the separate agent host.

### D. It still hangs without extensions

Check:

1. Remote CPU, memory, swap, disk space, and inodes.
2. Repository size and file count.
3. `time git status`.
4. Remote-SSH logs.
5. Remote server logs.
6. Filesystem or network-mounted repository performance.

### E. Logs indicate a damaged server installation

1. **LOCAL:** Confirm `code --version`.
2. **REMOTE:** Stop all VS Code processes.
3. Remove only the damaged matching `Stable-<commit>` directory.
4. Reconnect from one VS Code window.

---

## 18. Minimal Recovery Command Set

### LOCAL

```bash
code --version
pgrep -af '[c]ode'
```

Close all VS Code windows.

### REMOTE

```bash
pgrep -af '/home/webber/\.vscode-server/'

pkill -TERM -u "$USER" -f '/home/webber/\.vscode-server/'
sleep 3

pgrep -af '/home/webber/\.vscode-server/'
```

### LOCAL

Open one VS Code window and reconnect.

### REMOTE

Verify the newly started processes:

```bash
pgrep -af '/home/webber/\.vscode-server/'
```

Confirm that the main process containing:

```text
--connection-token=remotessh
```

uses the same commit reported by:

```bash
code --version
```

on the local desktop.

---

## 19. Current Conclusion for This Environment

The observed environment showed:

```text
LOCAL VS Code:
1.129.1
8a7abeba6e03ea3af87bfbce9a1b7e48fed567b8
```

The main Remote-SSH server correctly used:

```text
Stable-8a7abeba6e03ea3af87bfbce9a1b7e48fed567b8
```

A separate process set used:

```text
Stable-1b6a188127eeaf9194f945eb6eb89a657e93c54c
```

with:

```text
--agent-host-path
--without-connection-token
bootstrap-fork --type=agentHost
codex ... app-server
```

The best interpretation is:

- `Stable-8a7...` is the normal Remote-SSH server.
- `Stable-1b6...` is a separate agent-host runtime associated with agent/Codex functionality.
- The existence of both is not, by itself, evidence of corruption.
- To isolate the hang, first test with all extensions disabled, then disable or stop Codex specifically.
