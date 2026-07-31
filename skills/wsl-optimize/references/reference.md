# wsl-optimize — reference

## Commands & flags

| Command | Effect |
|---|---|
| `wslreport` | Read-only memory + disk + OOM-history report. |
| `wsl-optimize-doctor` | Read-only health check of tools *and* host posture. Exits non-zero on failure. |
| `wsl-reclaim` | Safe-tier cache reclaim (unattended-safe). |
| `wsl-reclaim --deep --dry-run` | Preview the deep tier — deletes nothing, prints each candidate and why. |
| `wsl-reclaim --deep` | Deep prune (prompts). `--yes` skips the prompt. |
| `wsl-reclaim --quiet` | Summary only (used by the timer). |
| `wsl-compact` | Report trapped vhdx space + print the Windows compaction commands. |
| `wsl-compact --json` | Machine-readable size/slack, for scripting. |
| `capmem <cmd>` | Run a command in a memory-capped systemd scope. |
| `capmem --status` | Show limits, delegation state, and live scopes. |
| `memguard --once -v` | Run one guard cycle by hand. |

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `KEEP_DAYS` | `30` | Age gate for the deep tier. |
| `KEEP_RECENT` | `5` | Always keep the N newest entries per category. |
| `CAPMEM_MAX` | `10G` | Hard cgroup memory ceiling. |
| `CAPMEM_HIGH` | `8G` | Throttle threshold (reclaim pressure before the kill). |
| `CAPMEM_TASKS` | `1024` | Task/thread ceiling. Node uses ~8–11 threads per process. |
| `WARN_MEM_PCT` | `15` | memguard acts below this % available RAM… |
| `WARN_SWAP_PCT` | `50` | …**and** below this % free swap. Both, deliberately. |
| `WARN_DISK_GB` | `20` | memguard reclaims below this many GB free. |
| `CRIT_DISK_GB` | `10` | memguard posts an urgent notice below this. |

Allowlist paths from deep pruning in `~/.config/wsl-reclaim/keep.txt` (one substring per line).

## Why the deep tier is trustworthy

Age alone is a bad signal — a project you use weekly but not in 30 days should not vanish. `--deep` removes only:

- **VS Code `workspaceStorage`** whose `workspace.json` points at a folder that **no longer exists**. If the project is still there it is kept regardless of age.
- **Agent transcripts** (`~/.claude/projects`, `~/.cache/claude-cli-nodejs`) that are idle past `KEEP_DAYS`, beyond the newest `KEEP_RECENT`, not currently open per `lsof`, and not matched by the allowlist.

## `.wslconfig` — the host-side half

Lives on Windows at `%UserProfile%\.wslconfig`. Requires `wsl --shutdown` to apply.

```ini
[wsl2]
memory=20GB              # default is 50% of host RAM
swap=16GB                # default is 25%. This is the important one.
autoMemoryReclaim=gradual # return idle memory to Windows
sparseVhd=true           # let freed space return to the host
```

Swap matters more than memory. Raising RAM moves the cliff; swap changes the *shape* of the failure from an instant crash into observable slowness you can react to.

## earlyoom — inverting the kernel's bad instinct

```bash
sudo apt-get install -y earlyoom
sudo tee /etc/default/earlyoom >/dev/null <<'EOF'
EARLYOOM_ARGS="-r 3600 -m 10 -s 40 --avoid '(^|/)(systemd|dbus-daemon|init|sshd|login)$' --prefer '(^|/)(node|python3)$'"
EOF
sudo systemctl restart earlyoom
```

`-m` and `-s` are **AND** conditions: earlyoom acts only when available RAM *and* free swap are both below threshold. Swap filling alone is normal; RAM pressure alone is what page cache is for.

Pick `-s` relative to swap size. With 16 GB of swap, `-s 20` means waiting until ~13 GB has paged out — unusable long before that. `-s 40` intervenes while recovery is possible.

**Verify with `ps`, not the config file.** `apt-get install` auto-starts the service, and `systemctl enable --now` is satisfied by "already running" — it does **not** restart. Config can sit on disk while stock args stay live:

```bash
ps -eo args | grep '[e]arlyoom'
journalctl -u earlyoom -b 0 | tail
```

## OOM forensics

Persistent journald is what makes a crash diagnosable — the default is volatile, so the crash erases its own evidence.

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
```

Then, after a crash:

```bash
journalctl --list-boots                 # a boot lasting minutes is your crash
journalctl -b -1 | tail -60
journalctl --no-pager | grep -E "Out of memory|oom-kill|Free swap"
```

`Free swap = 0kB` plus `global_oom` means genuine whole-VM exhaustion. To find what consumed it, parse the kernel's process table — **it dumps once per OOM event**, so divide counts by the number of dumps:

```bash
journalctl -b -1 --no-pager | grep -E "kernel: \[ *[0-9]+\] +$(id -u) " \
 | awk '{c[$NF]++; m[$NF]+=$11} END {for (k in c) printf "%-18s x%-4d %8.0f MB\n", k, c[k], m[k]*4/1024}' \
 | sort -k3 -rn | head
```

(`rss` is column 11, in 4 KiB pages.)

## Restoring trapped vhdx space

```powershell
wsl --manage <Distro> --set-sparse true   # future deletions return space (WSL 2.0+)
wsl --shutdown
Optimize-VHD -Path "<path>\ext4.vhdx" -Mode Full     # Hyper-V module + admin
# or: diskpart -> select vdisk file="..." -> attach vdisk readonly -> compact vdisk -> detach vdisk
```

Run `wsl-reclaim` first so you are not compacting garbage.

## Known limitation of `capmem`

`capmem` wraps things you launch from a **shell**, placing them in your user slice where the memory controller is delegated. Processes spawned by the VS Code server live in `init.scope`, outside that slice, and cannot be capped this way. `earlyoom` is the layer that covers them.
