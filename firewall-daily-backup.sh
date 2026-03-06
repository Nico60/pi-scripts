#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

BASE="${BASE:-${REAL_HOME}/backups}"
BACKUP_DIR="${BACKUP_DIR:-$BASE/firewall-backups}"
DATE="$(date +%F_%H%M%S)"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "=== $(date '+%F %T') $(basename "$0") START ==="
START_TS=$(date +%s)

install -d -m 700 -o "$REAL_USER" -g "$REAL_GROUP" "$BACKUP_DIR"

v4="$BACKUP_DIR/iptables_${DATE}.v4"
iptables-save > "$v4"
chmod 600 "$v4" 2>/dev/null || true
chown "$REAL_USER:$REAL_GROUP" "$v4" 2>/dev/null || true

if command -v ip6tables-save >/dev/null 2>&1; then
  v6="$BACKUP_DIR/ip6tables_${DATE}.v6"
  ip6tables-save > "$v6"
  chmod 600 "$v6" 2>/dev/null || true
  chown "$REAL_USER:$REAL_GROUP" "$v6" 2>/dev/null || true
fi

ls -1t "$BACKUP_DIR"/iptables_*.v4 2>/dev/null | tail -n +15 | xargs -r rm -f
ls -1t "$BACKUP_DIR"/ip6tables_*.v6 2>/dev/null | tail -n +15 | xargs -r rm -f

echo "Firewall backup OK: $DATE"
echo "=== $(date '+%F %T') $(basename "$0") END (duration=$(( $(date +%s) - START_TS ))s) ==="
