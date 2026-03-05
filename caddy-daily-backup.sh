#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Erreur ligne $LINENO: $BASH_COMMAND" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

BASE="${BASE:-${REAL_HOME}/stacks/caddy}"
BACKUP_DIR="${BACKUP_DIR:-$BASE/daily-backups}"
DATE="$(date +%F_%H%M%S)"
OUT="$BACKUP_DIR/caddy_${DATE}.tar.gz"

SERVICE_CADDY="${SERVICE_CADDY:-caddy}"
STOP_CADDY="${STOP_CADDY:-0}"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "=== $(date '+%F %T') $(basename "$0") START ==="
START_TS=$(date +%s)

command -v tar >/dev/null || { echo "tar introuvable"; exit 1; }
command -v docker >/dev/null || { echo "docker introuvable"; exit 1; }

test -d "$BASE" || { echo "Dossier introuvable: $BASE"; exit 1; }
test -f "$BASE/docker-compose.yml" || { echo "docker-compose.yml introuvable dans $BASE"; exit 1; }
test -f "$BASE/Caddyfile" || { echo "Caddyfile introuvable dans $BASE"; exit 1; }
test -d "$BASE/config" || { echo "config/ introuvable dans $BASE"; exit 1; }
test -d "$BASE/data" || { echo "data/ introuvable dans $BASE"; exit 1; }

install -d -m 700 -o "$REAL_USER" -g "$REAL_GROUP" "$BACKUP_DIR"
cd "$BASE"

docker compose config --services | grep -qx "$SERVICE_CADDY" \
  || { echo "Service '$SERVICE_CADDY' introuvable dans docker-compose.yml"; exit 1; }

STOPPED=0
cleanup() {
  if [[ "$STOPPED" -eq 1 ]]; then
    docker compose start "$SERVICE_CADDY" >/dev/null 2>&1 || true
  fi
  echo "=== $(date '+%F %T') $(basename "$0") END (duration=$(( $(date +%s) - START_TS ))s) ==="
}
trap 'cleanup' EXIT

if [[ "$STOP_CADDY" -eq 1 ]]; then
  docker compose stop "$SERVICE_CADDY" >/dev/null 2>&1 || true
  STOPPED=1
fi

items=(docker-compose.yml Caddyfile)
[[ -f .env ]] && items+=(.env)
[[ -d data ]] && items+=(data)
[[ -d config ]] && items+=(config)

tar -czf "$OUT" "${items[@]}"

chown "$REAL_USER:$REAL_GROUP" "$OUT" 2>/dev/null || true
chmod 600 "$OUT" 2>/dev/null || true

tar -tzf "$OUT" >/dev/null

ls -1t "$BACKUP_DIR"/caddy_*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f

echo "Backup OK: $OUT"
