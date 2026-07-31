---
name: wsl-optimize-setup
description: Install, configure, verify, or remove the wsl-optimize toolset on a WSL2 machine, and harden the host against silent OOM shutdowns. Use when the user says "install wsl-optimize", "set up WSL memory protection", "my WSL keeps dying", "set up disk automation for WSL", "harden WSL", is provisioning a fresh WSL distro, or wants to uninstall. Covers the tools, the systemd timers, .wslconfig tuning, earlyoom, and persistent journald.
compatibility: Requires WSL2 with systemd enabled. Some steps need sudo inside WSL and a Windows-side .wslconfig edit plus `wsl --shutdown`.
license: MIT
metadata:
  author: kylebrodeur
  version: "1.0"
---

# wsl-optimize-setup

Installing the tools is the easy half. The host posture — swap, earlyoom, persistent journald — is what actually stops the silent shutdown, and it lives partly on the Windows side.

## 1. Install the tools

```bash
git clone https://github.com/kylebrodeur/wsl-optimize.git
cd wsl-optimize
make install        # ~/.local/bin + systemd user timers
make doctor         # verify tools AND host posture
```

`~/.local/bin` must be on PATH. Put that in **`~/.zshenv`, not `~/.zshrc`** — `.zshrc` only runs for interactive shells, so editor tasks and MCP servers would get a different PATH and silently fall through to Windows binaries under `/mnt/c`.

If `make install` reports systemd is unavailable, enable it in `/etc/wsl.conf`, then `wsl --shutdown` from Windows:

```ini
[boot]
systemd=true
```

## 2. Host posture — work through whatever `doctor` flags

Run `wsl-optimize-doctor` and fix each ✗ in order. The three that matter most:

**Swap and memory** — `%UserProfile%\.wslconfig` on Windows, then `wsl --shutdown`:

```ini
[wsl2]
memory=20GB
swap=16GB
autoMemoryReclaim=gradual
sparseVhd=true
```

Swap is the important line: it turns an instant OOM into slowness you can see.

**earlyoom** — without `--avoid`/`--prefer` the kernel reaps dbus and systemd-user before the actual hogs, killing the whole VM:

```bash
sudo apt-get install -y earlyoom
sudo tee /etc/default/earlyoom >/dev/null <<'EOF'
EARLYOOM_ARGS="-r 3600 -m 10 -s 40 --avoid '(^|/)(systemd|dbus-daemon|init|sshd|login)$' --prefer '(^|/)(node|python3)$'"
EOF
sudo systemctl restart earlyoom
ps -eo args | grep '[e]arlyoom'    # VERIFY: enable --now does NOT restart a running unit
```

**Persistent journald** — otherwise every crash erases its own evidence:

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
```

Cap it in the same breath — unbounded, journald grows to 10% of the filesystem.

## 3. Wrap your agents

Add to `~/.zshrc` so agent CLIs run inside a memory cap:

```zsh
claude() { local b; b=$(whence -p claude) || return 127; capmem "$b" "$@"; }
```

This covers shell-launched processes only. Editor-spawned ones live in `init.scope`, outside the user slice — earlyoom is their protection.

## 4. Verify

```bash
wsl-optimize-doctor    # expect 0 failed
wslreport              # baseline: memory, vhdx gap, reclaimable caches
```

## Uninstall

```bash
make uninstall
```

Removes the tools and timers. It deliberately does **not** revert host settings (`.wslconfig`, earlyoom, journald) — those are independently useful and yours to keep. Logs and the allowlist are preserved.

## Install the agent skills

```bash
npx skills add kylebrodeur/wsl-optimize          # interactive
npx skills add kylebrodeur/wsl-optimize --list
make install-skills                              # Claude Code: symlink into ~/.claude/skills
```
