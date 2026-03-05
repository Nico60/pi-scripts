#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Erreur ligne $LINENO: $BASH_COMMAND" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

BASE="${BASE:-${REAL_HOME}/stacks/vaultwarden}"
COMPOSE_FILE="${BASE}/docker-compose.yml"

SERVICE_VAULT="${SERVICE_VAULT:-vaultwarden}"
IMAGE_VAULT="${IMAGE_VAULT:-vaultwarden/server:latest}"

CADDY_CONTAINER="${CADDY_CONTAINER:-caddy}"

ENV_FILE="${ENV_FILE:-$BASE/.env}"

[[ -f "$ENV_FILE" ]] || { echo "Fichier .env absent: $ENV_FILE"; exit 1; }

set -a
. "$ENV_FILE"
set +a

: "${VPN_VW_IP:?VPN_VW_IP manquant dans $ENV_FILE}"
: "${VPN_VW_PORT:?VPN_VW_PORT manquant dans $ENV_FILE}"
: "${HOST:?HOST manquant dans $ENV_FILE}"

CHECK_URL="${CHECK_URL:-https://${HOST}:${VPN_VW_PORT}/}"

NO_RESTART_IF_UPTODATE=0
if [ "${1:-}" = "--no-restart-if-uptodate" ]; then
  NO_RESTART_IF_UPTODATE=1
fi

echo "[1/10] Vérifs"
command -v docker >/dev/null || { echo "Docker introuvable"; exit 1; }
command -v curl >/dev/null || { echo "curl introuvable"; exit 1; }
test -d "$BASE" || { echo "Dossier manquant: $BASE"; exit 1; }
test -f "$COMPOSE_FILE" || { echo "Compose introuvable: $COMPOSE_FILE"; exit 1; }

VW_DATA="$BASE/data"
test -d "$VW_DATA" || { echo "Dossier data Vaultwarden manquant: $VW_DATA"; exit 1; }

echo "[2/10] Fingerprints de l'image AVANT pull"
before_vault="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE_VAULT" 2>/dev/null || true)"

echo "[3/10] Pull image"
docker pull "$IMAGE_VAULT" >/dev/null

after_vault="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE_VAULT" 2>/dev/null || true)"

UPDATED=0
if [ -z "$before_vault" ] && [ -n "$after_vault" ]; then UPDATED=1; fi
if [ -n "$before_vault" ] && [ "$before_vault" != "$after_vault" ]; then UPDATED=1; fi

if [ "${NO_RESTART_IF_UPTODATE:-0}" -eq 1 ] && [ "$UPDATED" -eq 0 ]; then
  echo
  echo "Image déjà à jour."
  exit 0
fi

if [ "$UPDATED" -eq 1 ]; then
  echo "[4/10] Backup Vaultwarden"
  TS="$(date +%F_%H%M%S)"
  BACKUP_DIR="$BASE/backups"
  install -d -m 700 -o "$REAL_USER" -g "$REAL_GROUP" "$BACKUP_DIR"

  tar -czf "$BACKUP_DIR/vaultwarden-data_$TS.tar.gz" -C "$BASE" data
  chown "$REAL_USER:$REAL_GROUP" "$BACKUP_DIR/vaultwarden-data_$TS.tar.gz" 2>/dev/null || true
  chmod 600 "$REAL_USER:$REAL_GROUP" "$BACKUP_DIR/vaultwarden-data_$TS.tar.gz" 2>/dev/null || true

  ls -1t "$BACKUP_DIR"/vaultwarden-data_*.tar.gz 2>/dev/null | tail -n +2 | xargs -r rm -f
else
  echo "[4/10] Backup: skip (image inchangée)"
fi

echo "[5/10] Recreate via docker compose"
cd "$BASE"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo "[6/10] Inspection"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | grep -E "(^| )(${SERVICE_VAULT})( |$)" || true

echo "[7/10] Attente conteneur running"
for i in {1..20}; do
  STATUS="$(docker inspect -f '{{.State.Status}}' "$SERVICE_VAULT" 2>/dev/null || true)"
  [ "$STATUS" = "running" ] && break
  sleep 1
done
test "${STATUS:-}" = "running" || {
  echo "Service $SERVICE_VAULT pas en running (status=$STATUS)"
  docker logs "$SERVICE_VAULT" --tail 200 || true
  exit 1
}

echo "[8/10] Attente healthcheck Vaultwarden"
HEALTH=""
SPINNER='|/-\'
k=0

for j in {1..120}; do
  HEALTH="$(docker inspect -f '{{.State.Health.Status}}' "$SERVICE_VAULT" 2>/dev/null || true)"
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
  echo "Vaultwarden pas healthy (dernier état: $HEALTH)"
  docker logs "$SERVICE_VAULT" --tail 200 || true
  exit 1
}

echo "[9/10] Test HTTPS applicatif"

echo "-> Test 1: URL (DNS): $CHECK_URL"
ok1=0
for i in {1..20}; do
  code="$(curl -k -sS -o /dev/null -w '%{http_code}' "$CHECK_URL" || true)"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    ok1=1
    echo "OK (HTTP $code)"
    break
  fi
  sleep 1
done

echo "-> Test 2: IP + SNI/Host: ${VPN_VW_IP}:${VPN_VW_PORT} host=$HOST"
ok2=0
for i in {1..20}; do
  code="$(curl -k -sS -o /dev/null -w '%{http_code}' \
    --resolve "${HOST}:${VPN_VW_PORT}:${VPN_VW_IP}" \
    "$CHECK_URL" || true)"
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    ok2=1
    echo "OK (HTTP $code)"
    break
  fi
  sleep 1
done

if [ "$ok1" -ne 1 ] && [ "$ok2" -ne 1 ]; then
  echo
  echo "ÉCHEC: l'app ne répond pas correctement en HTTPS."
  if docker inspect "$CADDY_CONTAINER" >/dev/null 2>&1; then
    echo "Derniers logs $CADDY_CONTAINER:"
    docker logs "$CADDY_CONTAINER" --tail 200 || true
  else
    echo "(Conteneur reverse-proxy '$CADDY_CONTAINER' introuvable, logs ignorés.)"
  fi
  echo
  echo "Derniers logs vaultwarden:"
  docker logs "$SERVICE_VAULT" --tail 200 || true
  exit 1
fi

echo "[10/10] Nettoyage"
docker image prune -f --filter "until=24h" >/dev/null 2>&1 || true

echo
if [ "$UPDATED" -eq 1 ]; then
  echo "Vaultwarden mis à jour + check OK."
else
  echo "Vaultwarden relancé + check OK (image inchangée)."
fi
