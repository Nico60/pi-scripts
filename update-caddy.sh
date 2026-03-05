#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Erreur ligne $LINENO: $BASH_COMMAND" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

BASE="${BASE:-${REAL_HOME}/stacks/caddy}"
COMPOSE_FILE="${BASE}/docker-compose.yml"

SERVICE_CADDY="${SERVICE_CADDY:-caddy}"
IMAGE_CADDY="${IMAGE_CADDY:-caddy:2}"

NO_RESTART_IF_UPTODATE=0
if [ "${1:-}" = "--no-restart-if-uptodate" ]; then
  NO_RESTART_IF_UPTODATE=1
fi

echo "[1/8] Vérifs"
command -v docker >/dev/null || { echo "Docker introuvable"; exit 1; }
test -d "$BASE" || { echo "Dossier manquant: $BASE"; exit 1; }
test -f "$COMPOSE_FILE" || { echo "Compose introuvable: $COMPOSE_FILE"; exit 1; }

echo "[2/8] Fingerprint image AVANT pull"
before_caddy="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE_CADDY" 2>/dev/null || true)"

echo "[3/8] Pull image"
docker pull "$IMAGE_CADDY" >/dev/null

after_caddy="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE_CADDY" 2>/dev/null || true)"

UPDATED=0
if [ -z "$before_caddy" ] && [ -n "$after_caddy" ]; then UPDATED=1; fi
if [ -n "$before_caddy" ] && [ "$before_caddy" != "$after_caddy" ]; then UPDATED=1; fi

if [ "${NO_RESTART_IF_UPTODATE:-0}" -eq 1 ] && [ "$UPDATED" -eq 0 ]; then
  echo
  echo "Image déjà à jour."
  exit 0
fi

if [ "$UPDATED" -eq 1 ]; then
  echo "[4/8] Backup Caddy"
  TS="$(date +%F_%H%M%S)"
  BACKUP_DIR="$BASE/backups"
  install -d -m 700 -o "$REAL_USER" -g "$REAL_GROUP" "$BACKUP_DIR"

  tar -czf "$BACKUP_DIR/caddy_$TS.tar.gz" \
    -C "$BASE" docker-compose.yml Caddyfile \
    data config 2>/dev/null || \
  tar -czf "$BACKUP_DIR/caddy_$TS.tar.gz" \
    -C "$BASE" docker-compose.yml Caddyfile

  chown "$REAL_USER:$REAL_GROUP" "$BACKUP_DIR/caddy_$TS.tar.gz" 2>/dev/null || true
  chmod 600 "$BACKUP_DIR/caddy_$TS.tar.gz" 2>/dev/null || true

  ls -1t "$BACKUP_DIR"/caddy_*.tar.gz 2>/dev/null | tail -n +2 | xargs -r rm -f
else
  echo "[4/8] Backup Caddy: skip (image inchangée)"
fi

echo "[5/8] Recreate via docker compose"
cd "$BASE"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo "[6/8] Inspection"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | grep -E "(^| )(${SERVICE_CADDY})( |$)" || true

echo "[7/8] Attente conteneur running"
for i in {1..20}; do
  STATUS="$(docker inspect -f '{{.State.Status}}' "$SERVICE_CADDY" 2>/dev/null || true)"
  [ "$STATUS" = "running" ] && break
  sleep 1
done

test "${STATUS:-}" = "running" || {
  echo "Service $SERVICE_CADDY pas en running (status=$STATUS)"
  docker logs "$SERVICE_CADDY" --tail 200 || true
  exit 1
}

echo "[8/8] Nettoyage"
docker image prune -f --filter "until=24h" >/dev/null 2>&1 || true

echo
if [ "$UPDATED" -eq 1 ]; then
  echo "Caddy mis à jour."
else
  echo "Caddy relancé (image inchangée)."
fi
