#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Erreur ligne $LINENO: $BASH_COMMAND" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

BASE="${BASE:-${REAL_HOME}/stacks/homeassistant}"
COMPOSE_FILE="${BASE}/docker-compose.yml"

SVC_HA="${SVC_HA:-homeassistant}"
SVC_MQTT="${SVC_MQTT:-mosquitto}"
SVC_Z2M="${SVC_Z2M:-zigbee2mqtt}"
SVC_GO2RTC="${SVC_GO2RTC:-go2rtc}"

IMG_HA="${IMG_HA:-ghcr.io/home-assistant/home-assistant:stable}"
IMG_MQTT="${IMG_MQTT:-eclipse-mosquitto:2}"
IMG_Z2M="${IMG_Z2M:-koenkk/zigbee2mqtt:latest}"
IMG_GO2RTC="${IMG_GO2RTC:-alexxit/go2rtc:latest}"

ENV_FILE="${ENV_FILE:-$BASE/.env}"

[[ -f "$ENV_FILE" ]] || { echo "Fichier .env absent: $ENV_FILE"; exit 1; }

set -a
. "$ENV_FILE"
set +a

: "${NW_HA_IP:?NW_HA_IP manquant dans $ENV_FILE}"
: "${NW_HA_PORT:?NW_HA_PORT manquant dans $ENV_FILE}"

CHECK_URL="${CHECK_URL:-http://${NW_HA_IP}:${NW_HA_PORT}/}"

NO_RESTART_IF_UPTODATE=0
if [[ "${1:-}" == "--no-restart-if-uptodate" ]]; then
  NO_RESTART_IF_UPTODATE=1
fi

echo "[1/9] Vérifs"
command -v docker >/dev/null || { echo "Docker introuvable"; exit 1; }
command -v curl >/dev/null || { echo "curl introuvable"; exit 1; }
test -d "$BASE" || { echo "Dossier manquant: $BASE"; exit 1; }
test -f "$COMPOSE_FILE" || { echo "Compose introuvable: $COMPOSE_FILE"; exit 1; }

echo "[2/9] Fingerprints AVANT pull"
before_ha="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMG_HA" 2>/dev/null || true)"
before_mqtt="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMG_MQTT" 2>/dev/null || true)"
before_z2m="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMG_Z2M" 2>/dev/null || true)"
before_go2rtc="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMG_GO2RTC" 2>/dev/null || true)"

echo "[3/9] Pull images"
docker pull "$IMG_HA" >/dev/null
docker pull "$IMG_MQTT" >/dev/null
docker pull "$IMG_Z2M" >/dev/null
docker pull "$IMG_GO2RTC" >/dev/null

after_ha="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMG_HA" 2>/dev/null || true)"
after_mqtt="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMG_MQTT" 2>/dev/null || true)"
after_z2m="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMG_Z2M" 2>/dev/null || true)"
after_go2rtc="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMG_GO2RTC" 2>/dev/null || true)"

UPDATED=0
[[ -z "$before_ha" && -n "$after_ha" ]] && UPDATED=1
[[ -z "$before_mqtt" && -n "$after_mqtt" ]] && UPDATED=1
[[ -z "$before_z2m" && -n "$after_z2m" ]] && UPDATED=1
[[ -z "$before_go2rtc" && -n "$after_go2rtc" ]] && UPDATED=1

[[ -n "$before_ha" && "$before_ha" != "$after_ha" ]] && UPDATED=1
[[ -n "$before_mqtt" && "$before_mqtt" != "$after_mqtt" ]] && UPDATED=1
[[ -n "$before_z2m" && "$before_z2m" != "$after_z2m" ]] && UPDATED=1
[[ -n "$before_go2rtc" && "$before_go2rtc" != "$after_go2rtc" ]] && UPDATED=1

if [[ "$NO_RESTART_IF_UPTODATE" -eq 1 && "$UPDATED" -eq 0 ]]; then
  echo
  echo "Images déjà à jour."
  exit 0
fi

if [[ "$UPDATED" -eq 1 ]]; then
  echo "[4/9] Backup Home Assistant stack"
  TS="$(date +%F_%H%M%S)"
  BACKUP_DIR="$BASE/backups"
  install -d -m 700 -o "$REAL_USER" -g "$REAL_GROUP" "$BACKUP_DIR"

  OUT="$BACKUP_DIR/homeassistant_$TS.tar.gz"

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

  ls -1t "$BACKUP_DIR"/homeassistant_*.tar.gz 2>/dev/null | tail -n +2 | xargs -r rm -f
else
  echo "[4/9] Backup: skip (images inchangées)"
fi

echo "[5/9] Recreate via docker compose"
cd "$BASE"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo "[6/9] Inspection"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" \
  | grep -E "(^| )(${SVC_HA}|${SVC_MQTT}|${SVC_Z2M}|${SVC_GO2RTC})( |$)" || true

echo "[7/9] Attente containers running"
for name in "$SVC_MQTT" "$SVC_Z2M" "$SVC_GO2RTC" "$SVC_HA"; do
  STATUS=""
  for i in {1..30}; do
    STATUS="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    [[ "$STATUS" == "running" ]] && break
    sleep 1
  done
  if [[ "$STATUS" != "running" ]]; then
    echo "Service $name pas en running (status=$STATUS)"
    docker logs "$name" --tail 200 || true
    exit 1
  fi
done

echo "[8/9] Check HTTP Home Assistant: $CHECK_URL"
ok=0
for i in {1..30}; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$CHECK_URL" || true)"
  if [[ "$code" == "200" || "$code" == "302" || "$code" == "401" ]]; then
    ok=1
    echo "OK (HTTP $code)"
    break
  fi
  sleep 1
done
if [[ "$ok" -ne 1 ]]; then
  echo "Avertissement: HA ne répond pas en HTTP sur $CHECK_URL."
fi

echo "[9/9] Nettoyage"
docker image prune -f --filter "until=24h" >/dev/null 2>&1 || true

echo
if [[ "$UPDATED" -eq 1 ]]; then
  echo "Home Assistant stack mis à jour."
else
  echo "Home Assistant stack relancé (images inchangées)."
fi
