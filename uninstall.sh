#!/usr/bin/env bash
# uninstall.sh — disable the timers and remove the deployed scripts.
# The repo is left intact; logs and your allowlist are preserved.
set -uo pipefail

BINDIR="$HOME/.local/bin"
UNITDIR="$HOME/.config/systemd/user"

if command -v systemctl >/dev/null 2>&1; then
  echo "Disabling systemd user units"
  for t in memguard.timer wsl-reclaim.timer; do
    systemctl --user disable --now "$t" >/dev/null 2>&1 && echo "  disabled $t" || true
  done
  for u in memguard.service memguard.timer wsl-reclaim.service wsl-reclaim.timer; do
    [ -f "$UNITDIR/$u" ] && rm -f "$UNITDIR/$u" && echo "  removed $u"
  done
  systemctl --user daemon-reload
  systemctl --user reset-failed 2>/dev/null || true
fi

echo "Removing scripts from $BINDIR"
for t in wslreport wsl-reclaim wsl-compact capmem memguard wsl-optimize-doctor; do
  [ -f "$BINDIR/$t" ] && rm -f "$BINDIR/$t" && echo "  $t"
done

rm -rf "$HOME/.local/lib/wsl-optimize" 2>/dev/null && echo "  shared library"

echo
echo "Left in place (delete manually if you want them gone):"
echo "  ~/.local/state/wsl-optimize/   logs"
echo "  ~/.config/wsl-reclaim/         deep-tier allowlist"
echo
echo "Note: uninstalling does NOT revert host-level settings you may have made"
echo "(.wslconfig, earlyoom, journald persistence). Those are yours to keep."
