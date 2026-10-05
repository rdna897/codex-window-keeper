#!/usr/bin/env bash
# Install codex-window-keeper as a systemd timer (run as root).  `./install.sh uninstall` removes it.
set -euo pipefail
NAME=codex-window-keeper

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root: sudo $0"
command -v systemctl >/dev/null || die "systemd is required"
cd "$(dirname "$0")"

if [[ "${1:-}" == uninstall ]]; then
  systemctl disable --now "$NAME.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/$NAME.service" "/etc/systemd/system/$NAME.timer" "/usr/local/bin/$NAME.sh"
  systemctl daemon-reload
  echo "Removed. Settings (/etc/default/$NAME) and state (/var/lib/$NAME) were kept; delete them to finish."
  exit 0
fi

# The job runs as the user who owns the Codex login (the sudo caller by default).
user="${KEEPER_USER:-${SUDO_USER:-root}}"
home="$(getent passwd "$user" | cut -d: -f6 || true)"
[[ -n "$home" ]] || die "unknown user: $user"
for dep in curl jq; do command -v "$dep" >/dev/null || die "$dep is required"; done
[[ -r "$home/.codex/auth.json" ]] || echo "warning: $home/.codex/auth.json not found; log in to Codex as $user first" >&2

install -m 755 "$NAME.sh" "/usr/local/bin/$NAME.sh"
# Keep existing settings on re-install.
[[ -e "/etc/default/$NAME" ]] || install -m 644 "$NAME.default" "/etc/default/$NAME"
sed "s|@USER@|$user|g; s|@HOME@|$home|g" "systemd/$NAME.service" > "/etc/systemd/system/$NAME.service"
chmod 644 "/etc/systemd/system/$NAME.service"
install -m 644 "systemd/$NAME.timer" "/etc/systemd/system/$NAME.timer"
install -d -m 700 -o "$user" "/var/lib/$NAME"

systemctl daemon-reload
systemctl enable --now "$NAME.timer"
echo "Installed for user '$user'. Current decision (dry run):"
runuser -u "$user" -- "/usr/local/bin/$NAME.sh" --dry-run || true
