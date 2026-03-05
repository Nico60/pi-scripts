#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Erreur ligne $LINENO: $BASH_COMMAND" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

BASE="${BASE:-${REAL_HOME}/stacks/vaultwarden}"
BACKUP_DIR="${BACKUP_DIR:-$BASE/daily-backups}"
DATE="$(date +%F_%H%M%S)"
TMP="$BACKUP_DIR/.vaultwarden_${DATE}.tar"
OUT="$BACKUP_DIR/vaultwarden_${DATE}.tar.gz"

SERVICE_VAULT="${SERVICE_VAULT:-vaultwarden}"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "=== $(date '+%F %T') $(basename "$0") START ==="
START_TS=$(date +%s)

command -v tar >/dev/null || { echo "tar introuvable"; exit 1; }
command -v docker >/dev/null || { echo "docker introuvable"; exit 1; }

test -d "$BASE" || { echo "Dossier introuvable: $BASE"; exit 1; }
test -f "$BASE/docker-compose.yml" || { echo "docker-compose.yml introuvable dans $BASE"; exit 1; }
test -d "$BASE/data" || { echo "data/ introuvable dans $BASE"; exit 1; }

install -d -m 700 -o "$REAL_USER" -g "$REAL_GROUP" "$BACKUP_DIR"
cd "$BASE"

docker compose config --services | grep -qx "$SERVICE_VAULT" \
  || { echo "Service '$SERVICE_VAULT' introuvable dans docker-compose.yml"; exit 1; }

STOPPED=0
cleanup() {
  if [[ "$STOPPED" -eq 1 ]]; then
    docker compose start "$SERVICE_VAULT" >/dev/null 2>&1 || true
  fi
  rm -f "$TMP" "$TMP.gz" 2>/dev/null || true
  echo "=== $(date '+%F %T') $(basename "$0") END (duration=$(( $(date +%s) - START_TS ))s) ==="
}
trap 'cleanup' EXIT

docker compose stop "$SERVICE_VAULT" >/dev/null 2>&1 || true
STOPPED=1

items=(data docker-compose.yml)
[[ -f "$BASE/.env" ]] && items+=(.env)

tar -cf "$TMP" -C "$BASE" "${items[@]}"

docker compose start "$SERVICE_VAULT" >/dev/null 2>&1 || true
STOPPED=0

gzip "$TMP"
mv -f "$TMP.gz" "$OUT"

chown "$REAL_USER:$REAL_GROUP" "$OUT" 2>/dev/null || true
chmod 600 "$OUT" 2>/dev/null || true

tar -tzf "$OUT" >/dev/null
ls -1t "$BACKUP_DIR"/vaultwarden_*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f

echo "Backup OK: $OUT"
