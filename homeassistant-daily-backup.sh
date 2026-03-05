#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Erreur ligne $LINENO: $BASH_COMMAND" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

BASE="${BASE:-${REAL_HOME}/stacks/homeassistant}"
BACKUP_DIR="${BACKUP_DIR:-$BASE/daily-backups}"
DATE="$(date +%F_%H%M%S)"
OUT="$BACKUP_DIR/homeassistant_${DATE}.tar.gz"

SERVICE_HA="${SERVICE_HA:-homeassistant}"
SERVICE_MQTT="${SERVICE_MQTT:-mosquitto}"
SERVICE_Z2M="${SERVICE_Z2M:-zigbee2mqtt}"
SERVICE_GO2RTC="${SERVICE_GO2RTC:-go2rtc}"

STOP_STACK="${STOP_STACK:-0}"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "=== $(date '+%F %T') $(basename "$0") START ==="
START_TS=$(date +%s)

command -v tar >/dev/null || { echo "tar introuvable"; exit 1; }
command -v docker >/dev/null || { echo "docker introuvable"; exit 1; }

test -d "$BASE" || { echo "Dossier introuvable: $BASE"; exit 1; }
test -f "$BASE/docker-compose.yml" || { echo "docker-compose.yml introuvable dans $BASE"; exit 1; }
test -d "$BASE/data/config" || { echo "Dossier manquant: $BASE/data/config"; exit 1; }
test -d "$BASE/mosquitto" || { echo "Dossier manquant: $BASE/mosquitto"; exit 1; }
test -d "$BASE/zigbee2mqtt/data" || { echo "Dossier manquant: $BASE/zigbee2mqtt/data"; exit 1; }
test -f "$BASE/go2rtc/go2rtc.yaml" || { echo "Fichier manquant: $BASE/go2rtc/go2rtc.yaml"; exit 1; }

install -d -m 700 -o "$REAL_USER" -g "$REAL_GROUP" "$BACKUP_DIR"
cd "$BASE"

for svc in "$SERVICE_HA" "$SERVICE_MQTT" "$SERVICE_Z2M" "$SERVICE_GO2RTC"; do
  docker compose config --services | grep -qx "$svc" \
    || { echo "Service '$svc' introuvable dans docker-compose.yml"; exit 1; }
done

STOPPED=0
cleanup() {
  if [[ "$STOPPED" -eq 1 ]]; then
    docker compose start "$SERVICE_MQTT" "$SERVICE_Z2M" "$SERVICE_GO2RTC" "$SERVICE_HA" >/dev/null 2>&1 || true
  fi
  echo "=== $(date '+%F %T') $(basename "$0") END (duration=$(( $(date +%s) - START_TS ))s) ==="
}
trap 'cleanup' EXIT

if [[ "$STOP_STACK" -eq 1 ]]; then
  docker compose stop "$SERVICE_HA" "$SERVICE_Z2M" "$SERVICE_GO2RTC" "$SERVICE_MQTT" >/dev/null 2>&1 || true
  STOPPED=1
fi

tar \
  --exclude='data/config/*.db' \
  --exclude='data/config/*.db-*' \
  --exclude='data/config/*.db-journal' \
  --exclude='mosquitto/data/*.db' \
  --exclude='mosquitto/data/*.db-*' \
  -czf "$OUT" -C "$BASE" -- \
  docker-compose.yml \
  data/config \
  mosquitto \
  zigbee2mqtt/data \
  go2rtc/go2rtc.yaml

chown "$REAL_USER:$REAL_GROUP" "$OUT" 2>/dev/null || true
chmod 600 "$OUT" 2>/dev/null || true

tar -tzf "$OUT" >/dev/null

ls -1t "$BACKUP_DIR"/homeassistant_*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f

echo "Backup OK: $OUT"
