#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Erreur ligne $LINENO: $BASH_COMMAND" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo"; exit 1; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

LOG_DIR="${LOG_DIR:-${REAL_HOME}/pi-update/logs}"
TS="$(date +%F_%H%M%S)"
LOG_FILE="$LOG_DIR/pi-update_$TS.log"

PIHOLE_SCRIPT="${PIHOLE_SCRIPT:-/usr/local/sbin/update-pihole.sh}"
UNBOUND_SCRIPT="${UNBOUND_SCRIPT:-/usr/local/sbin/update-unbound.sh}"
CADDY_SCRIPT="${CADDY_SCRIPT:-/usr/local/sbin/update-caddy.sh}"
VAULT_SCRIPT="${VAULT_SCRIPT:-/usr/local/sbin/update-vaultwarden.sh}"
HOMEASSISTANT_SCRIPT="${HOMEASSISTANT_SCRIPT:-/usr/local/sbin/update-homeassistant.sh}"

PIRONMAN_DIR="${PIRONMAN_DIR:-${REAL_HOME}/pironman5}"
PIRONMAN_SERVICE="${PIRONMAN_SERVICE:-pironman5.service}"

PIRONMAN_UPDATED=0
PIRONMAN_RESTARTED=0
PIRONMAN_DO_INSTALL=0
PIRONMAN_DO_RESTART=0

NO_RESTART_IF_UPTODATE=0
if [[ "${1:-}" == "--no-restart-if-uptodate" ]]; then
  NO_RESTART_IF_UPTODATE=1
fi

install -d -m 700 -o "$REAL_USER" -g "$REAL_GROUP" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
chown "$REAL_USER:$REAL_GROUP" "$LOG_FILE" 2>/dev/null || true
chmod 600 "$LOG_FILE" 2>/dev/null || true

echo "=== Update ALL @ $TS ==="
echo "Log: $LOG_FILE"
echo

echo "[1/11] Pré-checks"
command -v docker >/dev/null || { echo "docker introuvable"; exit 1; }
command -v apt >/dev/null || { echo "apt introuvable"; exit 1; }

[[ -x "$PIHOLE_SCRIPT" ]] || { echo "Script Pi-hole introuvable/exécutable: $PIHOLE_SCRIPT"; exit 1; }
[[ -x "$UNBOUND_SCRIPT" ]] || { echo "Script Unbound introuvable/exécutable: $UNBOUND_SCRIPT"; exit 1; }
[[ -x "$CADDY_SCRIPT" ]] || { echo "Script Caddy introuvable/exécutable: $CADDY_SCRIPT"; exit 1; }
[[ -x "$VAULT_SCRIPT" ]] || { echo "Script Vaultwarden introuvable/exécutable: $VAULT_SCRIPT"; exit 1; }
[[ -x "$HOMEASSISTANT_SCRIPT" ]] || { echo "Script HomeAssistant introuvable/exécutable: $HOMEASSISTANT_SCRIPT"; exit 1; }
[[ -d "$PIRONMAN_DIR" ]] || { echo "Dossier introuvable: $PIRONMAN_DIR"; exit 1; }

echo "OK: scripts détectés"
echo

echo "[2/11] Mise à jour Pi OS"
apt-get update

echo
echo "[3/11] Mise à niveau paquets"
export DEBIAN_FRONTEND=noninteractive
apt-get -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  full-upgrade

echo
echo "[4/11] Nettoyage système"
apt-get -y autoremove --purge
apt-get -y autoclean

echo
echo "[5/11] Mise à jour Pi-hole"
if [[ "$NO_RESTART_IF_UPTODATE" -eq 1 ]]; then
  "$PIHOLE_SCRIPT" --no-restart-if-uptodate
else
  "$PIHOLE_SCRIPT"
fi

echo
echo "[6/11] Mise à jour Unbound"
if [[ "$NO_RESTART_IF_UPTODATE" -eq 1 ]]; then
  "$UNBOUND_SCRIPT" --no-restart-if-uptodate
else
  "$UNBOUND_SCRIPT"
fi

echo
echo "[7/11] Mise à jour Caddy"
if [[ "$NO_RESTART_IF_UPTODATE" -eq 1 ]]; then
  "$CADDY_SCRIPT" --no-restart-if-uptodate
else
  "$CADDY_SCRIPT"
fi

echo
echo "[8/11] Mise à jour Vaultwarden"
if [[ "$NO_RESTART_IF_UPTODATE" -eq 1 ]]; then
  "$VAULT_SCRIPT" --no-restart-if-uptodate
else
  "$VAULT_SCRIPT"
fi

echo
echo "[9/11] Mise à jour Home Assistant"
if [[ "$NO_RESTART_IF_UPTODATE" -eq 1 ]]; then
  "$HOMEASSISTANT_SCRIPT" --no-restart-if-uptodate
else
  "$HOMEASSISTANT_SCRIPT"
fi

echo
echo "[10/11] Mise à jour Pironman5"

PIRONMAN_DO_INSTALL=0
PIRONMAN_DO_RESTART=0

if ! systemctl list-unit-files | awk '{print $1}' | grep -qx "$PIRONMAN_SERVICE"; then
  echo "Pironman5: service $PIRONMAN_SERVICE introuvable -> skip"
elif [[ ! -d "$PIRONMAN_DIR/.git" ]]; then
  echo "Pironman5: repo git introuvable dans $PIRONMAN_DIR -> skip"
  echo "   (Si besoin: export PIRONMAN_DIR=/chemin/vers/pironman5)"
else
  old_head="$(git -C "$PIRONMAN_DIR" rev-parse HEAD 2>/dev/null || echo "")"

  git -C "$PIRONMAN_DIR" fetch --prune
  git -C "$PIRONMAN_DIR" pull --ff-only

  new_head="$(git -C "$PIRONMAN_DIR" rev-parse HEAD 2>/dev/null || echo "")"

  if [[ -n "$old_head" && -n "$new_head" && "$old_head" != "$new_head" ]]; then
    PIRONMAN_UPDATED=1
    PIRONMAN_DO_INSTALL=1
    PIRONMAN_DO_RESTART=1
    echo "Pironman5: commit changé -> install.py + restart"
  else
    echo "Pironman5: déjà à jour"
    if [[ "$NO_RESTART_IF_UPTODATE" -eq 1 ]]; then
      echo "Pironman5: pas de restart"
    else
      :
    fi
  fi

  if [[ "$PIRONMAN_DO_INSTALL" -eq 1 ]]; then
    if [[ -f "$PIRONMAN_DIR/install.py" ]]; then
      if ! printf "n\n" | python3 "$PIRONMAN_DIR/install.py"; then
        python3 "$PIRONMAN_DIR/install.py"
      fi
    else
      echo "Pironman5: install.py introuvable dans $PIRONMAN_DIR -> skip install"
      PIRONMAN_DO_RESTART=0
    fi
  fi

  if [[ "$PIRONMAN_DO_RESTART" -eq 1 ]]; then
    systemctl daemon-reload || true
    systemctl restart "$PIRONMAN_SERVICE"
    if systemctl is-active --quiet "$PIRONMAN_SERVICE"; then
      PIRONMAN_RESTARTED=1
      echo "Pironman5: service OK (restart)"
    else
      echo "Pironman5: service KO après restart (voir status/journal)"
      systemctl --no-pager --full status "$PIRONMAN_SERVICE" || true
      journalctl -u "$PIRONMAN_SERVICE" -n 50 --no-pager || true
    fi
  fi
fi

echo
echo "[11/11] Résumé"
echo "- APT: terminé"
echo "- Pi-hole: terminé"
echo "- Unbound: terminé"
echo "- Caddy: terminé"
echo "- Vaultwarden: terminé"
echo "- Home Assistant: terminé"
echo "- Pironman5: $([[ "$PIRONMAN_UPDATED" -eq 1 ]] && echo "mis à jour" || echo "inchangé/skip")"
echo

echo "Versions rapides:"
uname -a || true
docker --version || true

echo
echo "Reboot système requis ?"

reboot_required=0
reason=()

if [[ -f /var/run/reboot-required ]]; then
  reboot_required=1
  reason+=("flag /var/run/reboot-required")
fi

running="$(uname -r)"
latest_2712="$(
  dpkg-query -W -f='${Package}\n' 'linux-image-*+rpt-rpi-2712' 2>/dev/null \
  | sed 's/^linux-image-//' \
  | sort -V \
  | tail -n 1
)"

if [[ -n "$latest_2712" && "$running" != "$latest_2712" ]]; then
  reboot_required=1
  reason+=("kernel en cours=$running, dernier installé=$latest_2712")
fi

if command -v needrestart >/dev/null 2>&1; then
  nr_out="$(NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 needrestart -b 2>/dev/null | tr -d '\r' || true)"

  if echo "$nr_out" | grep -qiE 'Pending kernel upgrade|Newer kernel available' \
     && ! echo "$nr_out" | grep -qiE 'expected kernel version .*rpt-rpi-v8'; then
    reboot_required=1
    reason+=("needrestart signale un kernel plus récent")
  fi
fi

if [[ "$reboot_required" -eq 1 ]]; then
  echo "OUI"
  printf ' - %s\n' "${reason[@]}"
  if [[ -f /var/run/reboot-required.pkgs ]]; then
    echo
    echo "Paquets concernés:"
    cat /var/run/reboot-required.pkgs 2>/dev/null || true
  fi
else
  echo "NON"
fi

echo
echo "=== FIN OK ==="
