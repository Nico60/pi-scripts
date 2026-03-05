#!/usr/bin/env bash
set -Eeuo pipefail

SRC="/boot/firmware"
DEV0="/dev/nvme0n1p1"
DEV1="/dev/nvme1n1p1"
MNT="/mnt/nvme-boot-sync"

LOCK="/run/sync-nvme-boot.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

if [[ ! -b "$DEV0" || ! -b "$DEV1" ]]; then
  logger -t sync-nvme-boot "NVMe boot partitions absentes -> skip"
  exit 0
fi

CUR="$(findmnt -n -o SOURCE "$SRC" || true)"

if [[ "$CUR" == "$DEV0" ]]; then
  DST="$DEV1"
elif [[ "$CUR" == "$DEV1" ]]; then
  DST="$DEV0"
else
  logger -t sync-nvme-boot "/boot/firmware n'est pas sur nvme0/nvme1 ($CUR) -> skip"
  exit 0
fi

install -d -m 755 "$MNT"
if mountpoint -q "$MNT"; then umount "$MNT" || true; fi

mount "$DST" "$MNT"
rsync -aHAX --delete "$SRC"/ "$MNT"/
sync
umount "$MNT"
rmdir "$MNT" 2>/dev/null || true

echo "OK -> synced /boot/firmware to $DST"
logger -t sync-nvme-boot "OK -> synced /boot/firmware to $DST"
