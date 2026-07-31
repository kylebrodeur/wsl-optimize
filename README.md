# wsl-optimize

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: WSL2](https://img.shields.io/badge/platform-WSL2-0078D6.svg?logo=windows&logoColor=white)](#requirements)
[![Shell: bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnu-bash&logoColor=white)](#)
[![Dependencies: none](https://img.shields.io/badge/deps-none-success.svg)](#requirements)
[![Agent Skills](https://img.shields.io/badge/Agent%20Skills-agentskills.io-8A2BE2.svg)](https://agentskills.io)

> Memory & disk hygiene for a **WSL2 box that runs a lot of AI coding agents** — diagnose, reclaim safely, bound the runaways, and reclaim the space your virtual disk is silently hoarding, without ever deleting work that isn't provably recoverable.

Companion to [`mac-optimize`](https://github.com/kylebrodeur/mac-optimize). That project was a macOS port of a WSL2 OOM writeup; this brings the structure back to WSL2, where the original failure lives — and where there are **two** silent killers instead of one.

## The two failures

**Memory.** WSL2 gets a fixed slice of host RAM. When it runs out, the kernel OOM killer ranks candidates by `oom_score_adj` — and on a systemd distro, session plumbing scores *higher* than your workload:

| Process | `oom_score_adj` | Outcome |
|---|---|---|
| your agent fleet (node, python) | **0** | **survives** |
| `dbus-daemon` | 200 | killed |
| user `systemd` | 100 | killed |

So the kernel **protects the memory hogs and dismantles the session.** VS Code disconnects, the distro shuts down, and there is no error anywhere — because nothing survived long enough to write one. The real incident behind this repo: 27 Node processes at ~635 MB each, aggregating to 14.4 GB in a 15.7 GB VM, with swap exhausted to `0kB`. No single process looked guilty.

**Disk.** The `ext4.vhdx` only ever **grows**. Delete 20 GB inside WSL and `df` reports 20 GB freed while Windows gets back exactly nothing. "I have plenty of room" inside can coexist with a full host disk. This repo's own machine: **132 GB vhdx, 116 GB actually used — 16 GB trapped.**

Both have the same shape as the macOS disk problem: **aggregate, invisible, no single culprit.** The design goal is the same too — change the failure from *silent and fatal* to *observable and bounded*.

## Quickstart

```bash
git clone https://github.com/kylebrodeur/wsl-optimize.git
cd wsl-optimize
make install          # tools → ~/.local/bin + systemd user timers
make doctor           # verify the install AND the host's posture

wslreport             # where did my memory and disk go? (read-only)
wsl-reclaim           # reclaim safe caches now
wsl-compact           # how much is trapped in the vhdx, and how to get it back
```

`~/.local/bin` must be on your PATH — set it in `~/.zshenv`, **not** `~/.zshrc`, so non-interactive shells (editor tasks, MCP servers) see it too. Re-running `make install` is safe.

## Tools

| Tool | What it does |
|---|---|
| **`wslreport`** | Read-only "where did it go" — memory/swap headroom, top consumers grouped by command, OOM kill history from journald, **vhdx size vs. actual usage**, regrowing caches, and large agent/editor state. Deletes nothing. |
| **`wsl-optimize-doctor`** | Read-only health check of the tools *and the host*: swap, `.wslconfig`, earlyoom's `--avoid`/`--prefer`, persistent journald, cgroup delegation, Node tools resolving to `/mnt/c` Windows binaries, dangling PATH symlinks, PATH duplicates. Exits non-zero on failure. |
| **`wsl-reclaim`** | Two tiers. **Safe** (default) clears caches the owning tool rebuilds on demand — safe *by construction*. **`--deep`** prunes stale agent state only with *evidence* it's unused, behind `--dry-run`, an allowlist, `lsof` guards, and a keep-newest floor. |
| **`wsl-compact`** | Measures the space trapped in the `ext4.vhdx` and prints the exact Windows-side commands to reclaim it. **Guided, never automatic** — compaction requires `wsl --shutdown`, which kills every running agent. |
| **`capmem`** | Runs a command inside a memory-capped systemd scope, so a runaway fleet is killed by its own cgroup instead of taking the VM down. `capmem --status` shows limits and live scopes. |
| **`memguard`** | The systemd-timer watcher (a `diskguard` analog). Every 30 min: on combined memory+swap pressure or low disk it runs the **safe** reclaim, logs, and posts a Windows toast. Never kills a process, never prunes unattended. |

## How it works

Four principles, in order of trust — the same ladder as `mac-optimize`:

1. **Observable before action.** `wslreport` and `wsl-optimize-doctor` answer "what's wrong" without touching anything. On WSL that includes making the *invisible* visible: the vhdx gap, and OOM history that a volatile journal would have erased.
2. **Safe by construction.** The default reclaim only clears caches the owning tool rebuilds on demand. `pnpm`/`uv` prune only *unreferenced* packages; npm's `_cacache` is a re-download cache; installed `node_modules` are never touched. It **cannot** remove something you're using.
3. **Evidence before deletion.** The deep tier requires *proof*: workspace state whose project folder is gone; state that's idle **and** beyond keep-newest **and** not held open **and** not allowlisted. Age alone is never sufficient.
4. **Bounded automation.** `memguard` runs unattended but only ever the safe tier, only at a threshold. `capmem` bounds a fleet *before* it becomes an incident. Nothing destructive ever runs without a human.

## Options

| Command | Effect |
|---|---|
| `wslreport` | Read-only memory + disk + OOM report. |
| `wsl-reclaim` | Safe-tier reclaim (unattended-safe). |
| `wsl-reclaim --deep --dry-run` | Preview the deep tier — deletes nothing, prints each candidate and why. |
| `wsl-reclaim --deep [--yes]` | Deep prune (prompts unless `--yes`). |
| `wsl-compact [--json]` | Trapped-space report + Windows compaction commands. |
| `capmem <cmd>` / `capmem --status` | Run capped / inspect limits and live scopes. |
| `memguard --once -v` | Run one guard cycle by hand. |

| Var | Default | Meaning |
|---|---|---|
| `KEEP_DAYS` | `30` | Age gate for the deep tier. |
| `KEEP_RECENT` | `5` | Always keep the N newest entries per category. |
| `CAPMEM_MAX` / `CAPMEM_HIGH` | `10G` / `8G` | Hard ceiling / throttle threshold. |
| `WARN_MEM_PCT` / `WARN_SWAP_PCT` | `15` / `50` | memguard acts when **both** are breached. |
| `WARN_DISK_GB` / `CRIT_DISK_GB` | `20` / `10` | Disk thresholds. |

Allowlist paths from deep pruning in `~/.config/wsl-reclaim/keep.txt` (one substring per line).

### The host-side half

The tools can't fix the host on their own. `wsl-optimize-doctor` checks these and tells you what's missing:

```ini
# %UserProfile%\.wslconfig  (Windows side; needs `wsl --shutdown`)
[wsl2]
memory=20GB
swap=16GB                 # the important one: turns a hard OOM into visible slowness
autoMemoryReclaim=gradual
sparseVhd=true
```

```bash
# earlyoom — inverts the kernel's instinct to protect the hogs
sudo apt-get install -y earlyoom
sudo tee /etc/default/earlyoom >/dev/null <<'EOF'
EARLYOOM_ARGS="-r 3600 -m 10 -s 40 --avoid '(^|/)(systemd|dbus-daemon|init|sshd|login|wsl-gpu-guard)$' --prefer '(^|/)(node|python3)$'"
EOF
sudo systemctl restart earlyoom     # NOT `enable --now` — that won't restart a running unit
```

```bash
# persistent journald — otherwise a crash erases its own evidence
sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
```

`earlyoom`'s `-m`/`-s` are **AND** conditions — it acts only when RAM *and* swap are both low. Swap filling alone is normal; RAM pressure alone is what page cache is for.

### Why `capmem` isn't the whole answer

`capmem` places work in your **user slice**, where the memory controller is delegated. Processes spawned by the VS Code server live in `init.scope`, outside that slice, and can't be capped this way. That's the gap `earlyoom` covers. Use both.

## Requirements

WSL2 with **systemd enabled** (`[boot] systemd=true` in `/etc/wsl.conf`). Pure **bash** — no runtime dependencies. `pnpm`, `uv`, `bun`, `cargo`, and `pip` caches are pruned only if present (each guarded by `command -v`). `wslreport`/`wsl-compact` read the vhdx size through Windows interop and degrade gracefully without it.

## Automation & uninstall

`make install` enables two systemd **user** timers:

- `memguard.timer` — 2 min after startup, then every 30 min
- `wsl-reclaim.timer` — weekly, Sundays 11:00

The unit files are templates: systemd doesn't expand `$HOME` in `ExecStart` and user units start with a near-empty environment, so `install.sh` substitutes `__HOME__`/`__PATH__` at install time. Nothing is hardcoded to one machine.

```bash
make uninstall      # disables timers, removes deployed scripts; repo + host settings left intact
```

## Agent skills

`skills/` ships **agent-agnostic** skills in the open [Agent Skills](https://agentskills.io) format (a `SKILL.md` per folder — no vendor lock-in). Any skills-compatible agent (Claude Code, Gemini CLI, Cursor, opencode, Goose, …) can load them.

| Skill | Triggers on |
|---|---|
| **`wsl-optimize`** | "WSL crashed / keeps dying", "VS Code disconnected from WSL", "free up space", "what's using my memory", "compact the vhdx" — diagnose → safe reclaim → deep dry-run → compaction. |
| **`wsl-optimize-setup`** | "install wsl-optimize", "set up WSL memory protection", "harden WSL", fresh-distro setup, uninstall. |

```bash
npx skills add kylebrodeur/wsl-optimize          # interactive: pick skills + agents
npx skills add kylebrodeur/wsl-optimize --list   # list what's available
make install-skills                              # Claude Code: symlink into ~/.claude/skills
```

## Related tools

These solve adjacent problems well; this repo defers to them rather than shipping weaker copies.

| Tool | Why |
|---|---|
| [`agent-session-kill`](https://github.com/kylebrodeur/agent-session-kill) | Agent transcript cleanup, done properly: trash-first deletion, protection lists for auth/settings/skills/memory, and coverage of Pi/OMP/Copilot Chat as well as Claude. `wsl-reclaim --deep` **delegates to it when installed** and only falls back to its own conservative pruning otherwise. |
| [`wsl-gpu-guard`](https://github.com/kylebrodeur/wsl-gpu-guard) | A *third* cause of silent WSL death: on Optimus laptops the dGPU powers off when AC is unplugged, `/dev/dxg` vanishes, and any process holding a CUDA context takes WSL2 down with it. `wsl-optimize-doctor` checks whether it is running and whether earlyoom is configured to protect it. |
| [`mac-optimize`](https://github.com/kylebrodeur/mac-optimize) | The macOS sibling. Its `worktree-audit` is pure git and runs unmodified here. |
| [`agent-machine-lib`](https://github.com/kylebrodeur/agent-machine-lib) | The shared bash primitives both this repo and `mac-optimize` vendor. |

## Not included: git worktree auditing

Stray agent worktrees are a real disk sink on WSL too, but the tool for it — `worktree-audit` — is pure git and already solid in [`mac-optimize`](https://github.com/kylebrodeur/mac-optimize). It runs unmodified here. Rather than fork a copy that drifts, install that repo alongside this one if you want it.

## Background

The WSL2 OOM forensics writeup this grew out of: [Diagnosing a silent WSL2 shutdown](https://gist.github.com/kylebrodeur/68059cbfdc0f4b1d9d483fe466e4de1b).

## License

MIT © 2026 Kyle Brodeur
