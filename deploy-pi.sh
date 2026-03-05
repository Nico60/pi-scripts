#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-$HOME/dev/pi-scripts/deploy_pi.env}"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
: "${PI_HOST:?Missing PI_HOST}"

LOCAL_ROOT="${LOCAL_ROOT:-$HOME/dev/pi-scripts}"
REMOTE_SBIN="${REMOTE_SBIN:-/usr/local/sbin}"
RSYNC_BIN="${RSYNC_BIN:-/usr/bin/rsync}"
LOCAL_PRIVATE_DIR="${LOCAL_PRIVATE_DIR:-$LOCAL_ROOT/private}"

RSYNC_ROOT=(--rsync-path="sudo ${RSYNC_BIN}")

echo "[1/2] Deploy public scripts -> ${REMOTE_SBIN}"
rsync -av --progress "${RSYNC_ROOT[@]}" \
  --exclude '.git/' \
  --exclude 'private/' \
  --exclude 'deploy-pi.sh' \
  --exclude 'deploy_pi.env' \
  --include '*/' \
  --include '*.sh' \
  --exclude '*' \
  --chown=root:root \
  --chmod=F700 \
  "$LOCAL_ROOT/" \
  "$PI_HOST:${REMOTE_SBIN}/"

echo "[2/2] Deploy private scripts -> ${REMOTE_SBIN}"
if [[ -d "$LOCAL_PRIVATE_DIR" ]]; then
  rsync -av --progress "${RSYNC_ROOT[@]}" \
    --include '*/' \
    --include '*.sh' \
    --exclude '*' \
    --chown=root:root \
    --chmod=F700 \
    "$LOCAL_PRIVATE_DIR/" \
    "$PI_HOST:${REMOTE_SBIN}/"
else
  echo "NOTE: $LOCAL_PRIVATE_DIR not found, skipping private deploy."
fi

echo "Done."
