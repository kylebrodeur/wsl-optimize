#!/usr/bin/env bash
# install.sh — deploy the tooling into ~/.local/bin and enable the systemd user
# timers. Idempotent: safe to re-run.
#
# Portable: the unit files are templates. systemd does not expand $HOME or ~ in
# ExecStart, and user units start with a near-empty environment, so __HOME__ and
# __PATH__ are substituted here for the current user rather than hardcoded.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BINDIR="$HOME/.local/bin"
UNITDIR="$HOME/.config/systemd/user"

# PATH baked into the units. Covers the common Node/Python version managers;
# every tool inside the scripts is `command -v`-guarded, so absent ones are
# simply skipped.
U_PATH="$HOME/.local/bin:$HOME/.local/share/pnpm/bin:$HOME/.local/share/pnpm:$HOME/.bun/bin:$HOME/.cargo/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

mkdir -p "$BINDIR" "$UNITDIR"

echo "Installing scripts → $BINDIR"
for f in "$REPO"/bin/*; do
  install -m 0755 "$f" "$BINDIR/$(basename "$f")"
  echo "  $(basename "$f")"
done

if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
  cat <<'WARN'

systemd user manager is not available. The tools are installed and usable, but
the timers were skipped. WSL needs systemd enabled — put this in /etc/wsl.conf
and run `wsl --shutdown` from Windows:

  [boot]
  systemd=true
WARN
  exit 0
fi

LIBDIR="$HOME/.local/lib/wsl-optimize"
echo "Installing shared library → $LIBDIR"
mkdir -p "$LIBDIR"
install -m 0644 "$REPO/lib/common.sh" "$LIBDIR/common.sh"
echo "  common.sh (vendored from agent-machine-lib)"

echo "Installing + enabling systemd user units → $UNITDIR"
for u in "$REPO"/systemd/*; do
  n="$(basename "$u")"
  sed -e "s|__HOME__|$HOME|g" -e "s|__PATH__|$U_PATH|g" "$u" > "$UNITDIR/$n"
  echo "  $n"
done

systemctl --user daemon-reload
for t in memguard.timer wsl-reclaim.timer; do
  # `enable --now` is satisfied by "already running" and will NOT pick up a
  # changed unit file — the classic way a config edit looks applied but isn't.
  # Enable for boot, then restart explicitly so re-running the installer
  # actually applies the new schedule.
  systemctl --user enable "$t" >/dev/null 2>&1 || { echo "  WARNING: could not enable $t"; continue; }
  systemctl --user restart "$t" >/dev/null 2>&1 && echo "  enabled + started $t" \
    || echo "  WARNING: could not start $t"
done

# Linger keeps the timers running when no login session is open. Not fatal
# without it — WSL usually has a session — so a failure here is informational.
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$USER" >/dev/null 2>&1 \
    && echo "  lingering enabled (timers survive with no open shell)" \
    || echo "  note: could not enable lingering (needs sudo); timers run while a shell is open"
fi

echo
echo "Active timers:"
systemctl --user list-timers --no-pager 2>/dev/null | grep -E 'memguard|wsl-reclaim' || echo "  (none — check errors above)"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo; echo "NOTE: $BINDIR is not on your PATH. Add it in ~/.zshenv (not ~/.zshrc)"
     echo "      so non-interactive shells — editor tasks, MCP servers — see it too." ;;
esac

echo
echo "Next: wsl-optimize-doctor    # verify the install and the host's memory/disk posture"
