#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Erreur ligne $LINENO: $BASH_COMMAND" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

BASE="${BASE:-${REAL_HOME}/stacks/pihole}"
COMPOSE_FILE="${BASE}/docker-compose.yml"
CONFIG="$BASE/pihole.env"
ETC_PIHOLE="$BASE/etc-pihole"
ETC_DNSMASQ="$BASE/etc-dnsmasq.d"

SERVICE_PIHOLE="${SERVICE_PIHOLE:-pihole}"
IMAGE_PIHOLE="${IMAGE_PIHOLE:-pihole/pihole:latest}"

NO_RESTART_IF_UPTODATE=0
if [ "${1:-}" = "--no-restart-if-uptodate" ]; then
  NO_RESTART_IF_UPTODATE=1
fi

echo "[1/7] Vérifs"
command -v docker >/dev/null || { echo "Docker introuvable"; exit 1; }
command -v timeout >/dev/null || { echo "timeout introuvable (coreutils ?)"; exit 1; }
test -d "$BASE" || { echo "Dossier manquant: $BASE"; exit 1; }
test -f "$COMPOSE_FILE" || { echo "Compose introuvable: $COMPOSE_FILE"; exit 1; }
test -f "$CONFIG" || { echo "Fichier env introuvable: $CONFIG"; exit 1; }
chmod 600 "$CONFIG" 2>/dev/null || true
test -d "$ETC_PIHOLE" || { echo "Dossier manquant: $ETC_PIHOLE"; exit 1; }
test -d "$ETC_DNSMASQ" || { echo "Dossier manquant: $ETC_DNSMASQ"; exit 1; }

echo "[2/7] Fingerprint image AVANT pull"
before="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE_PIHOLE" 2>/dev/null || true)"

echo "[3/7] Pull image"
docker pull "$IMAGE_PIHOLE" >/dev/null
after="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE_PIHOLE" 2>/dev/null || true)"

UPDATED=0
if [ -z "$before" ] && [ -n "$after" ]; then
  UPDATED=1
elif [ -n "$before" ] && [ "$before" != "$after" ]; then
  UPDATED=1
fi

if [ "${NO_RESTART_IF_UPTODATE:-0}" -eq 1 ] && [ "$UPDATED" -eq 0 ]; then
  echo
  echo "Image déjà à jour."
  exit 0
fi

if [ "$UPDATED" -eq 1 ]; then
  echo "[4/7] Backup config"
  TS="$(date +%F_%H%M%S)"
  BACKUP_DIR="$BASE/backups"
  install -d -m 700 -o "$REAL_USER" -g "$REAL_GROUP" "$BACKUP_DIR"

  tar -czf "$BACKUP_DIR/pihole-config_$TS.tar.gz" -C "$BASE" etc-pihole etc-dnsmasq.d
  chown "$REAL_USER:$REAL_GROUP" "$BACKUP_DIR/pihole-config_$TS.tar.gz" 2>/dev/null || true
  chmod 600 "$BACKUP_DIR/pihole-config_$TS.tar.gz" 2>/dev/null || true

  ls -1t "$BACKUP_DIR"/pihole-config_*.tar.gz 2>/dev/null | tail -n +2 | xargs -r rm -f
else
  echo "[4/7] Backup: skip (image déjà à jour)"
fi

echo "[5/7] Recreate via docker compose"
cd "$BASE"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo "[6/7] Docker inspection"
docker ps --filter "name=^/$SERVICE_PIHOLE}$" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

echo "Container name: $SERVICE_PIHOLE"
for i in {1..10}; do
  STATUS="$(docker inspect -f "{{.State.Status}}" "$SERVICE_PIHOLE" 2>/dev/null || true)"
  echo "Status: $STATUS"
  [ "$STATUS" = "running" ] && break
  sleep 1
done
test "$STATUS" = "running"

echo "[7/7] Nettoyage & check"
docker image prune -f --filter "until=24h" >/dev/null 2>&1 || true

echo "Attente Pi-hole..."
for i in {1..30}; do
  if docker exec "$SERVICE_PIHOLE" pihole status >/dev/null 2>&1; then
    echo "Pi-hole OK"
    break
  fi
  sleep 1
done

docker exec "$SERVICE_PIHOLE" pihole status >/dev/null 2>&1 || {
  echo "Pi-hole pas prêt"
  docker logs "$SERVICE_PIHOLE" --tail 200 || true
  exit 1
}

echo "Attente healthcheck Docker..."
HEALTH=""
PREV=""
SPINNER='|/-\'
k=0

for j in {1..120}; do
  HEALTH="$(docker inspect -f '{{.State.Health.Status}}' "$SERVICE_PIHOLE" 2>/dev/null || true)"
  [ -z "$HEALTH" ] && HEALTH="unknown"

  if [ "$HEALTH" = "healthy" ] || [ "$HEALTH" = "unhealthy" ]; then
    printf "\rHealth: %-10s    \n" "$HEALTH"
    break
  fi

  c="${SPINNER:k%4:1}"
  printf "\rHealth: %-10s %s" "$HEALTH" "$c"
  k=$((k+1))
  sleep 1
done

test "$HEALTH" = "healthy" || {
  echo "Healthcheck pas healthy (dernier état: $HEALTH)"
  docker logs "$SERVICE_PIHOLE" --tail 200 || true
  exit 1
}

echo
docker exec "$SERVICE_PIHOLE" pihole -v || true
echo

if [ "$UPDATED" -eq 1 ]; then
  echo "Pi-hole mis à jour (nouvelle image installée)."
else
  echo "Pi-hole déjà à jour (image inchangée)."
fi

docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.CreatedSince}}\t{{.ID}}" \
  | grep -E '^pihole/pihole\s+latest' || true
