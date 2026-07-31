---
name: wsl-optimize
description: Diagnose and fix memory and disk exhaustion on a WSL2 dev machine that runs many AI coding agents. Use when WSL feels slow, runs out of memory or disk, when VS Code disconnects from WSL or the distro shuts down with no error, when the user says "WSL crashed", "WSL keeps dying", "free up space", "what's using my memory", "reclaim disk", "compact the vhdx", or for routine maintenance. Drives the wslreport, wsl-reclaim, wsl-compact, capmem, and wsl-optimize-doctor command-line tools with a safety-first workflow.
compatibility: Requires WSL2 with systemd enabled and the wsl-optimize tools on PATH (wslreport, wsl-reclaim, wsl-compact, capmem, wsl-optimize-doctor). Install from the wsl-optimize repo (see the wsl-optimize-setup skill).
license: MIT
metadata:
  author: kylebrodeur
  version: "1.0"
---

# wsl-optimize

Keep a WSL2 coding-agent machine alive — **without ever deleting work that isn't provably recoverable.**

WSL2 has two silent aggregate failures. Both look like "no single guilty process":

- **Memory.** The kernel OOM killer ranks by `oom_score_adj`, where session plumbing (dbus 200, systemd-user 100) outranks the actual hogs (node, 0). So it *protects* the memory hogs and dismantles the session — the whole VM dies with **no error anywhere**, and the terminal just reopens as if nothing happened.
- **Disk.** The `ext4.vhdx` only ever **grows**. Deleting files inside WSL frees space to `df` and returns *nothing* to Windows.

## 1. Diagnose first (read-only)

```
wslreport
```

Memory and swap headroom, top consumers grouped by command, OOM kill history from journald, **vhdx size vs. actual usage** (the trapped-space gap), regrowing caches, and large agent/editor state. Deletes nothing.

If the complaint is "WSL died with no error", also check the host posture:

```
wsl-optimize-doctor
```

Every check maps to a real failure: missing swap, no `earlyoom` `--avoid`/`--prefer`, a volatile journal that erases its own crash evidence, missing cgroup delegation, Node tools resolving to `/mnt/c` Windows binaries (9P-slow), dangling PATH symlinks.

## 2. Reclaim safe caches

```
wsl-reclaim
```

Clears only caches the owning tool rebuilds on demand. **Safe by construction**, not by carefulness: `pnpm store prune`/`uv cache prune` remove only unreferenced packages, npm's `_cacache` is a re-download cache, installed `node_modules` are never touched. Run freely.

## 3. Deeper reclaim — ALWAYS dry-run first

```
wsl-reclaim --deep --dry-run     # every candidate + WHY it is considered unused
wsl-reclaim --deep               # prompts before deleting
```

Evidence-based, not age-based: VS Code `workspaceStorage` whose project folder **no longer exists**; agent transcripts idle past `KEEP_DAYS` **and** beyond the newest `KEEP_RECENT` **and** not open (`lsof`) **and** not in `~/.config/wsl-reclaim/keep.txt`. Never run `--deep --yes` unless the user reviewed a dry-run.

## 4. Return trapped space to Windows

```
wsl-compact
```

Reports how much is trapped in the vhdx and prints the exact Windows-side commands. **Guided, never automatic** — compaction needs `wsl --shutdown`, which kills every running agent. Always run `wsl-reclaim` first so you are not compacting garbage.

## 5. Bound a runaway before it kills the VM

```
capmem <command>              # run inside a 10 GB cgroup scope
CAPMEM_MAX=14G capmem <cmd>   # raise for one run
```

Wrap agent fleets so an OOM is confined to that cgroup — the runaway dies, the VM lives. Note this only covers processes launched from a **shell**; anything spawned by the editor lives in `init.scope`, outside the user slice, where `earlyoom` is the protection.

## The rule

Caches are safe-by-construction — clear them. Anything that could hold unrecoverable work is **backed up or left alone, never deleted**. When unsure, prefer `wslreport` and `--dry-run` over action.

## Details

Full flag/env tables, the deep-tier guards, `.wslconfig` tuning, and the OOM forensics recipe are in [references/reference.md](references/reference.md). Load it only when you need specifics.
