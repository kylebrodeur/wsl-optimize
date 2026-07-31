# TESTING — wsl-optimize

End-to-end verification on WSL2: clone → install → run → maintain → uninstall.

Unlike the macOS sibling, this document has been executed on a real WSL2 box. The
"expected" values below are what it actually produced. Every destructive step is
gated behind a dry-run whose correctness you assert first. If a **STOP** check
fails, stop and report it.

---

## 0. Prerequisites

```bash
wsl.exe --version | tr -d '\r\0' | head -2      # WSL 2.0+ for --set-sparse
cat /etc/wsl.conf                               # need [boot] systemd=true
systemctl --user is-system-running               # want: running
bash --version | head -1
command -v git python3 lsof
free -h; df -h /
```

**STOP if:** `systemctl --user` errors — the timers need systemd. Add to
`/etc/wsl.conf` and `wsl --shutdown` from Windows:

```ini
[boot]
systemd=true
```

`python3` and `lsof` are optional but recommended: without `lsof` the deletion
guard deliberately treats everything as in-use (safe, but the deep tier finds
nothing).

Record: WSL version, RAM/swap, free space.

## 1. Clone

```bash
git clone https://github.com/kylebrodeur/wsl-optimize.git
cd wsl-optimize
git log --oneline -3
```

## 2. Build

No build step — pure bash, zero runtime dependencies.

```bash
for f in bin/* install.sh uninstall.sh lib/common.sh; do bash -n "$f" || echo "PARSE FAIL: $f"; done
cat lib/.vendored-from        # the agent-machine-lib commit vendored here
make lint                     # shellcheck if installed
```

**STOP if:** anything prints `PARSE FAIL`.

Library in isolation:

```bash
bash -c '. lib/common.sh
  echo "platform: $AM_PLATFORM"       # must be: wsl2
  am_is_wsl && echo "am_is_wsl: yes" || echo "am_is_wsl: NO — BUG"
  echo "mtime \$HOME: $(am_mtime "$HOME")"
  echo "free KiB: $(am_free_kb /)"
'
```

**STOP if:** `AM_PLATFORM` is not `wsl2`, or `am_mtime` returns `0`.

## 3. Install

```bash
make install
make doctor
```

**Expect:** `0 failed`. Warnings are informational — on the reference box it
reports 24 passed / 3 warnings / 0 failed, the warnings being dangling PATH
symlinks and non-existent PATH dirs contributed by other tooling.

Verify independently:

```bash
ls -l ~/.local/lib/wsl-optimize/common.sh
systemctl --user list-timers --all | grep -E 'memguard|wsl-reclaim'
grep -c '__HOME__\|__PATH__' ~/.config/systemd/user/{memguard,wsl-reclaim}.{service,timer}   # all 0
```

**STOP if:** any unit still contains `__HOME__`/`__PATH__`, or `memguard.timer`
shows an empty `NEXT` column. An empty `NEXT` means the timer will never fire
again — note `is-enabled` and `is-active` both report "fine" in that state, so
`list-timers` is the only check that catches it.

### 3a. The installed-copy trap

The repo copy working does not mean the installed copy works — an earlier bug had
`worktree-audit` silently classify zero entries once installed, because it
couldn't locate the library.

```bash
cd /tmp && worktree-audit | grep -cE 'SAFE|REVIEW'
cd -   && ./bin/worktree-audit | grep -cE 'SAFE|REVIEW'
```

**Expect:** identical counts. **STOP if:** the installed copy prints
`cannot find lib/common.sh` or returns 0 where the repo copy returned more.

## 4. Run

### 4a. Read-only first

```bash
wslreport
```

**Expect** sections for memory, top consumers grouped by command, OOM history,
disk inside WSL, **the vhdx gap**, regrowing caches with a reclaimable total, and
a REVIEW tier. Deletes nothing.

On the reference box this surfaced 7.8 GB reclaimable and ~16 GB trapped in the
vhdx. If `wslreport` warns that journald is volatile, fix that first — otherwise
the next crash erases its own evidence:

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
```

### 4b. Host posture

Work through every ✗ from `wsl-optimize-doctor`. The three that matter:

```bash
# swap — turns a hard OOM into visible slowness. %UserProfile%\.wslconfig, then `wsl --shutdown`
#   [wsl2]
#   memory=20GB
#   swap=16GB
#   autoMemoryReclaim=gradual
#   sparseVhd=true

# earlyoom — protects the session, targets the hogs
sudo apt-get install -y earlyoom
sudo tee /etc/default/earlyoom >/dev/null <<'EOF'
EARLYOOM_ARGS="-r 3600 -m 10 -s 40 --avoid '(^|/)(systemd|dbus-daemon|init|sshd|login|wsl-gpu-guard)$' --prefer '(^|/)(node|python3)$'"
EOF
sudo systemctl restart earlyoom          # NOT `enable --now` — see below
ps -eo args | grep '[e]arlyoom'          # verify the PROCESS, not the file
```

**`systemctl enable --now` does not restart an already-running unit.** `apt-get
install` auto-starts earlyoom, so `--now` is satisfied by "it's running" and your
config sits on disk unused. Always confirm with `ps`.

### 4c. Safe tier — dry-run, assert it frees nothing

```bash
before=$(df -Pk / | awk 'NR==2{print $4}')
./bin/wsl-reclaim --deep --dry-run
after=$(df -Pk / | awk 'NR==2{print $4}')
echo "delta KiB: $((after-before))    # must be ~0"
```

**Expect:** `would:` lines, deep candidates each with a reason, delta ≈ 0.
**STOP if:** delta is materially negative.

### 4d. Safe tier for real

```bash
wsl-reclaim
```

Re-run immediately — should reclaim ≈0 (idempotent). If it freed a lot, it will
remind you that space inside WSL is not returned to Windows until you compact.

### 4e. The vhdx

```bash
wsl-compact            # read-only: reports trapped space + prints the commands
wsl-compact --json     # machine-readable
```

**Expect:** vhdx size, used inside, and a trapped figure. It **never** compacts
for you — that requires `wsl --shutdown`, which kills every running agent. Run
`wsl-reclaim` first so you aren't compacting garbage, then follow the printed
Windows-side steps and re-run `wsl-compact` to confirm the gap closed.

### 4f. capmem

```bash
capmem --status                       # limits + delegation + live scopes
capmem bash -c 'cat /sys/fs/cgroup$(cat /proc/self/cgroup|cut -d: -f3)/memory.max'
```

**Expect:** `memory controller delegated`, and the cap echoed in bytes
(10737418240 for the 10G default).

Prove containment — the child should die while your session survives:

```bash
systemd-run --user --scope --quiet -p MemoryMax=256M -p MemorySwapMax=0 -- \
  python3 -c "b=[]
for i in range(200): b.append(bytearray(10*1024*1024))
print('NOT capped — BUG')"
echo "exit=$?"
systemctl --user is-system-running     # want: running
systemctl --user reset-failed
```

**Expect:** no `NOT capped` output (the child was killed), session still healthy.

**Known limitation:** `capmem` only covers processes launched from a **shell**.
Anything the VS Code server spawns lives in `init.scope`, outside the delegated
user slice, and cannot be capped this way — `earlyoom` is what covers those.

### 4g. Worktrees

```bash
worktree-audit
worktree-audit --backup      # archive REVIEW ones
worktree-audit --prune       # remove SAFE ones
```

Hand-verify one SAFE classification before pruning:

```bash
git -C <repo> log --oneline <branch> --not $(git -C <repo> for-each-ref --format='%(refname)' refs/heads refs/tags refs/remotes | grep -vxF refs/heads/<branch>) | wc -l
```

**Expect:** `0`. **STOP if** non-zero for a SAFE row.

### 4h. memguard

```bash
memguard --once --verbose
tail -5 ~/.local/state/wsl-optimize/memguard.log
```

**Expect:** an `ok mem_avail=..% swap_free=..%` line when there's no pressure. It
acts only when memory **and** swap are both low — swap filling alone is normal,
and RAM pressure alone is what page cache is for.

## 5. Maintain

```bash
make doctor                  # expect 0 failed
make vendor-lib              # refresh shared lib + worktree-audit
git diff --stat              # drift from agent-machine-lib@main
```

If `vendor-lib` produces a diff, re-run the section 2 library checks before
committing.

**Idempotency:**

```bash
make install && make install && make doctor
systemctl --user list-timers --all | grep -E 'memguard|wsl-reclaim'   # NEXT still populated
```

`install.sh` deliberately does `enable` then `restart` rather than `enable --now`,
so re-running actually applies a changed schedule.

Timers: `memguard` 2 min after start then every 30 min; `wsl-reclaim` weekly
Sundays 11:00.

```bash
journalctl --user -u memguard.service -n 20 --no-pager
```

## 6. Uninstall

```bash
make uninstall
```

Assert zero residue:

```bash
ls ~/.local/bin/{wslreport,wsl-reclaim,wsl-compact,capmem,memguard,worktree-audit,wsl-optimize-doctor} 2>/dev/null | wc -l  # want 0
ls ~/.local/lib/wsl-optimize/ 2>/dev/null | wc -l                                    # want 0
ls ~/.config/systemd/user/{memguard,wsl-reclaim}.{service,timer} 2>/dev/null | wc -l # want 0
systemctl --user list-timers --all | grep -cE 'memguard|wsl-reclaim'                 # want 0
systemctl --user --failed --no-legend | wc -l                                        # want 0
```

Preserved on purpose: `~/.local/state/wsl-optimize/` logs and
`~/.config/wsl-reclaim/keep.txt`.

Uninstall deliberately does **not** revert host settings (`.wslconfig`, earlyoom,
journald persistence) — those are independently useful.

---

## Results template

```
WSL version:      
RAM / swap:       
free space before:

2  parse                 pass / fail:
2  library isolation     AM_PLATFORM=      am_mtime=
3  make install          pass / fail:
3  make doctor           passed=   warnings=   failed=
3  timers NEXT populated Y/N
3a installed vs repo     counts match? Y/N
4a wslreport             reclaimable=   MiB   vhdx trapped=   GB
4b host posture          swap=  earlyoom --avoid=  journald persistent=
4c dry-run delta KiB           (must be ~0)
4d wsl-reclaim reclaimed       MiB    idempotent on re-run? Y/N
4e wsl-compact           trapped=   GB   (compaction attempted? Y/N)
4f capmem cap enforced   Y/N    containment test killed child? Y/N
4g worktree-audit        SAFE=   REVIEW=   hand-verified? Y/N
4h memguard              log line present? Y/N
5  vendor-lib drift      none / diff:
5  install idempotent    Y/N
6  uninstall residue     bins=  lib=  units=  timers=  failed=   (all want 0)

Anything unexpected:
```
