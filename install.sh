#!/usr/bin/env bash

set -euo pipefail

LAN_NET="securius-lan"
SUITE_NET="securius-suite"
HUB_NAME="securius-hub"
HUB_IMAGE="ghcr.io/securius-core/securius-hub:latest"
HUB_PORT="48080"
# mDNS name the Hub is reached by. The Hub CONTAINER (image ≥0.3.1) runs avahi and
# advertises this name on its OWN IP. When Hub gets a macvlan LAN IP, Docker disables the
# container's host-port publishing, so the container's macvlan IP is the only reachable
# path — the container MUST own securius-hub.local. But if the HOST is also named
# securius-hub it publishes securius-hub.local at the (unreachable) host IP and WINS the
# mDNS name, forcing the container to rename to securius-hub-2.local. So on the
# macvlan-success path we yield the name from the host by renaming it to $HOST_ALT_NAME.
HUB_HOSTNAME="securius-hub"
HOST_ALT_NAME="securius-device"
# Set true once Hub actually holds its macvlan/qnet LAN IP (see start_hub).
MACVLAN_OK="false"
DATA_VOL="hub_data"
HOST_SOCKET="/var/run/docker.sock"
CHANNEL_VOL="securius-update-channel"
UPDATER_NAME="securius-hub-updater"
UPDATER_IMAGE="ghcr.io/securius-core/securius-hub-updater:latest"
# QNAP's inherited container DNS (host 10.0.3.1, via Docker's embedded resolver) resolves
# names intermittently → EAI_AGAIN. The infra containers that reach the internet BY NAME
# (Hub → api.securius.net; updater → ghcr.io) use explicit reliable resolvers instead.
# On the user-defined securius-suite network, --dns only changes the embedded resolver's
# UPSTREAM — Hub's container-name resolution (→ products) still works. Pi-hole is NOT
# touched here: it keeps its own Dns config (127.0.0.1 + upstream) from Hub's Branch A spec.
DNS_PRIMARY="1.1.1.1"
DNS_FALLBACK="8.8.8.8"
OCTET_HIGH=98
OCTET_LOW=50

if [ -t 1 ]; then
  C_B="\033[1m"; C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_0="\033[0m"
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
info() { printf "%b\n" "${C_B}==>${C_0} $*"; }
ok()   { printf "%b\n" "${C_G}  ok${C_0} $*"; }
warn() { printf "%b\n" "${C_Y}  ! ${C_0} $*" >&2; }
die()  { printf "%b\n" "${C_R}ERROR:${C_0} $*" >&2; exit 1; }

DOCKER="docker"

# Root wrapper for the few non-Docker host commands (hostnamectl, systemctl, editing
# /etc/hosts) used by the mDNS-ownership step. Empty when already root; "sudo" otherwise.
# If neither applies the mDNS step degrades gracefully (warns + skips).
SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

HOST_TYPE="linux"
detect_host_type() {
  info "Detecting host type"
  if [ -f /etc/config/uLinux.conf ] || command -v getcfg >/dev/null 2>&1 \
     || $DOCKER network ls --format '{{.Driver}}' 2>/dev/null | grep -qiw qnet; then
    HOST_TYPE="qnap"
    ok "Detected QNAP / Container Station"
  elif [ -f /etc/synoinfo.conf ] || [ -f /etc.defaults/synoinfo.conf ] \
       || command -v synogetkeyvalue >/dev/null 2>&1; then
    # Synology: BEST-EFFORT, UNVERIFIED on real hardware. Attempts the generic Linux
    # detection/macvlan path; bails honestly if any step fails. Do NOT add Synology-
    # specific interface guesses (bond0/eth0/ovs_eth0 vary by model) until validated.
    HOST_TYPE="synology"
    ok "Detected Synology / Container Manager"
  else
    HOST_TYPE="linux"
    ok "Detected standard Linux"
  fi
}

is_nas() { [ "$HOST_TYPE" = "qnap" ] || [ "$HOST_TYPE" = "synology" ]; }

ensure_docker() {
  info "Checking Docker"
  if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed — $(docker --version 2>/dev/null || echo 'version unknown') (not reinstalling)"
  else
    install_docker
  fi
  resolve_docker_cmd
  detect_compose
}

install_docker() {
  if is_nas; then
    die "Docker is not installed on this NAS, and the generic Docker installer does not
     work on NAS firmware. Install it from your NAS App Center, then re-run this script:
       QNAP     ->  Container Station
       Synology ->  Container Manager"
  fi
  info "Docker not found — installing via the official get.docker.com script"
  command -v curl >/dev/null 2>&1 || die "curl is required to install Docker. Install curl and re-run."
  if [ "$(id -u)" -eq 0 ]; then
    curl -fsSL https://get.docker.com | sh || die "Docker installation failed."
  elif command -v sudo >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sudo sh || die "Docker installation failed."
  else
    die "Docker is missing and this user can't elevate (no sudo). Re-run as root."
  fi
  ok "Docker installed"
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    sudo usermod -aG docker "$(id -un)" 2>/dev/null || true
  fi
}

resolve_docker_cmd() {
  if docker info >/dev/null 2>&1; then
    DOCKER="docker"
  elif [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
    warn "Using 'sudo docker' (the 'docker' group isn't active in this session yet)."
  else
    if [ "$(id -u)" -ne 0 ]; then
      die "Can't reach the Docker daemon as user '$(id -un)'. Re-run as root, e.g.:
       curl -fsSL <url>/install.sh | sudo bash
     or add your user to the 'docker' group:  sudo usermod -aG docker $(id -un)  (then log out/in)."
    fi
    die "Docker daemon is not reachable (is it running?). Try: systemctl start docker"
  fi
  ok "Docker daemon reachable"
}

detect_compose() {
  if $DOCKER compose version >/dev/null 2>&1; then
    ok "Docker Compose v2 available"
  elif command -v docker-compose >/dev/null 2>&1; then
    ok "Docker Compose v1 (legacy) available"
  else
    warn "Docker Compose not found — not required by this installer; continuing."
  fi
}

GATEWAY=""; IFACE=""; HOST_IP=""; PREFIX=""; SUBNET_CIDR=""; BASE3=""
qnet_param() {
  local net
  net="$($DOCKER network ls --filter driver=qnet --format '{{.Name}}' 2>/dev/null | head -n1)"
  [ -n "$net" ] || return 0
  $DOCKER network inspect "$net" --format "{{range .IPAM.Config}}{{.$1}}{{\"\n\"}}{{end}}" 2>/dev/null \
    | grep -v '^$' | head -n1 || true
}
lan_die() {
  if [ "$HOST_TYPE" = "synology" ]; then
    die "Synology auto-configuration is BEST-EFFORT and has NOT been verified on real
     Synology hardware. $1
     We won't guess at Synology-specific network settings — set Hub up manually or contact
     Securius support."
  fi
  die "$1"
}
detect_lan() {
  info "Detecting LAN parameters from the host"

  command -v ip >/dev/null 2>&1 || lan_die "'ip' command not found; cannot detect networking."

  local route gw iface
  route="$(ip route 2>/dev/null | grep '^default ' | head -n1 || true)"
  [ -n "$route" ] || lan_die "Could not find a default route in 'ip route' output."
  gw="$(awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' <<<"$route")"
  iface="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$route")"
  [ -n "$gw" ] && [ -n "$iface" ] \
    || lan_die "Could not parse gateway/interface from default route: '$route'"
  GATEWAY="$gw"; IFACE="$iface"

  local cidr
  cidr="$(ip addr show "$IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="inet"){print $(i+1); exit}}' || true)"
  [ -n "$cidr" ] || lan_die "Interface '$IFACE' has no IPv4 address."
  HOST_IP="${cidr%/*}"
  PREFIX="${cidr#*/}"
  BASE3="${HOST_IP%.*}"

  SUBNET_CIDR="$(network_cidr "$HOST_IP" "$PREFIX")"

  if [ "$HOST_TYPE" = "qnap" ]; then
    local qsub qgw
    qsub="$(qnet_param Subnet)"
    qgw="$(qnet_param Gateway)"
    if [ -n "$qsub" ] && [ "$qsub" != "$SUBNET_CIDR" ]; then
      warn "qnet network reports subnet $qsub; host route gave $SUBNET_CIDR. Using qnet value."
      SUBNET_CIDR="$qsub"
    fi
    if [ -n "$qgw" ] && [ "$qgw" != "$GATEWAY" ]; then
      warn "qnet network reports gateway $qgw; host route gave $GATEWAY. Using qnet value."
      GATEWAY="$qgw"
    fi
  fi

  ok "Interface : $IFACE"
  ok "Host IP   : $HOST_IP/$PREFIX"
  ok "Gateway   : $GATEWAY"
  ok "Subnet    : $SUBNET_CIDR"

  if [ "$PREFIX" != "24" ]; then
    warn "Subnet prefix is /$PREFIX, not /24. The .$OCTET_LOW–.$OCTET_HIGH claim window is"
    warn "evaluated within ${BASE3}.0/24; on an unusual prefix double-check the result."
  fi
}

ip_to_int() { local IFS=.; read -r a b c d <<<"$1"; echo "$(( (a<<24)+(b<<16)+(c<<8)+d ))"; }
int_to_ip() { local i=$1; echo "$(( (i>>24)&255 )).$(( (i>>16)&255 )).$(( (i>>8)&255 )).$(( i&255 ))"; }
network_cidr() {
  local ip_int mask net
  ip_int="$(ip_to_int "$1")"
  if [ "$2" -eq 0 ]; then mask=0; else mask=$(( (0xFFFFFFFF << (32 - $2)) & 0xFFFFFFFF )); fi
  net=$(( ip_int & mask ))
  echo "$(int_to_ip "$net")/$2"
}

PING_OPTS="-c1 -W1"
select_ping() {
  if ping -c1 -W1 127.0.0.1 >/dev/null 2>&1; then PING_OPTS="-c1 -W1"
  elif ping -c1 -w1 127.0.0.1 >/dev/null 2>&1; then PING_OPTS="-c1 -w1"
  else PING_OPTS="-c1"; warn "ping has no usable timeout flag; address probes may be slow."; fi
}
is_alive() { ping $PING_OPTS "$1" >/dev/null 2>&1; }

HUB_IP=""
pick_hub_ip() {
  info "Selecting a free LAN IP for Hub (.$OCTET_HIGH → .$OCTET_LOW)"
  select_ping
  local octet candidate
  for (( octet=OCTET_HIGH; octet>=OCTET_LOW; octet-- )); do
    candidate="${BASE3}.${octet}"
    [ "$candidate" = "$GATEWAY" ] && continue
    [ "$candidate" = "$HOST_IP" ] && continue
    if is_alive "$candidate"; then continue; fi
    HUB_IP="$candidate"
    break
  done
  [ -n "$HUB_IP" ] \
    || die "No free address found in ${BASE3}.$OCTET_LOW–.$OCTET_HIGH. Free one up and re-run."
  ok "Chose $HUB_IP for Hub"
}

net_exists() { $DOCKER network inspect "$1" >/dev/null 2>&1; }

create_suite_network() {
  info "Ensuring internal bridge '$SUITE_NET'"
  if net_exists "$SUITE_NET"; then
    ok "'$SUITE_NET' already exists"
  else
    $DOCKER network create "$SUITE_NET" >/dev/null \
      || die "Failed to create bridge network '$SUITE_NET'."
    ok "Created bridge '$SUITE_NET'"
  fi
}

# Shared volume the Hub and the updater sidecar exchange update-request/status files
# through. Must exist before either container mounts it. Idempotent.
ensure_channel_volume() {
  info "Ensuring update channel volume '$CHANNEL_VOL'"
  if $DOCKER volume inspect "$CHANNEL_VOL" >/dev/null 2>&1; then
    ok "'$CHANNEL_VOL' already exists"
  else
    $DOCKER volume create "$CHANNEL_VOL" >/dev/null \
      || die "Failed to create volume '$CHANNEL_VOL'."
    ok "Created volume '$CHANNEL_VOL'"
  fi
}

create_lan_network() {
  info "Ensuring LAN network '$LAN_NET'"

  if [ "$HOST_TYPE" = "qnap" ]; then
    if net_exists "$LAN_NET" && [ "$(net_driver "$LAN_NET")" = "qnet" ]; then
      ok "Reusing existing qnet network '$LAN_NET'"
      return
    fi
    local existing
    existing="$($DOCKER network ls --filter driver=qnet --format '{{.Name}}' | head -n1)"
    if [ -n "$existing" ]; then
      LAN_NET="$existing"
      ok "Reusing existing qnet network '$LAN_NET'"
      return
    fi
    warn "No qnet network found. Attempting CLI creation (often unsupported on QTS)…"
    if $DOCKER network create -d qnet \
         --subnet="$SUBNET_CIDR" --gateway="$GATEWAY" \
         -o iface="$IFACE" --ipam-opt iface="$IFACE" \
         "$LAN_NET" >/dev/null 2>&1; then
      ok "Created qnet network '$LAN_NET'"
    else
      die "Could not create a qnet network from the CLI on this QNAP firmware.
     Create one in Container Station, then re-run this script:
       Container Station → Network → Create → 'Use a physical NIC' / static IP range
       on your LAN ($SUBNET_CIDR, gateway $GATEWAY). Name it '$LAN_NET' (or any name —
       this script will detect and reuse any existing qnet network)."
    fi
    return
  fi

  if net_exists "$LAN_NET"; then
    ok "'$LAN_NET' already exists"
    return
  fi
  $DOCKER network create -d macvlan \
    --subnet="$SUBNET_CIDR" --gateway="$GATEWAY" \
    -o parent="$IFACE" \
    "$LAN_NET" >/dev/null \
    || lan_die "Failed to create macvlan network '$LAN_NET' on parent '$IFACE'.
     The NIC may not allow macvlan (promiscuous mode), or '$IFACE' is wrong."
  ok "Created macvlan '$LAN_NET' (parent $IFACE)"
}

net_driver() { $DOCKER network inspect "$1" --format '{{.Driver}}' 2>/dev/null; }

container_exists() { $DOCKER ps -a --format '{{.Names}}' | grep -qx "$HUB_NAME"; }
container_running() { [ "$($DOCKER inspect -f '{{.State.Running}}' "$HUB_NAME" 2>/dev/null)" = "true" ]; }
on_network() { $DOCKER inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$HUB_NAME" 2>/dev/null | grep -qw "$1"; }

start_hub() {
  info "Pulling Hub image (public, no login required)"
  $DOCKER pull "$HUB_IMAGE" >/dev/null || die "Failed to pull $HUB_IMAGE"
  ok "Image ready"

  if container_exists; then
    warn "Container '$HUB_NAME' already exists — not recreating."
    container_running || { $DOCKER start "$HUB_NAME" >/dev/null && ok "Started existing '$HUB_NAME'"; }
  else
    info "Starting Hub on '$SUITE_NET'"
    # The $CHANNEL_VOL mount at /channel is how Hub hands self-update requests to the
    # securius-hub-updater sidecar. The updater recreates Hub from its LIVE config
    # (docker inspect), so this mount — like the LAN IP, ports and /data — carries
    # through any future self-update automatically: the running Hub container is the
    # single source of truth for its own spec.
    $DOCKER run -d \
      --name "$HUB_NAME" \
      --restart unless-stopped \
      --dns "$DNS_PRIMARY" \
      --dns "$DNS_FALLBACK" \
      --network "$SUITE_NET" \
      -p 48080-48090:48080-48090 \
      -e PORT="$HUB_PORT" \
      -e DOCKER_SOCKET="$HOST_SOCKET" \
      -e DATA_DIR=/data \
      -v "$HOST_SOCKET:$HOST_SOCKET" \
      -v "$DATA_VOL:/data" \
      -v "$CHANNEL_VOL:/channel" \
      "$HUB_IMAGE" >/dev/null \
      || die "Failed to start the Hub container."
    ok "Hub container started"
  fi

  if on_network "$LAN_NET"; then
    ok "Hub already attached to '$LAN_NET'"
    MACVLAN_OK="true"
  else
    info "Attaching Hub to '$LAN_NET' at $HUB_IP"
    if $DOCKER network connect --ip "$HUB_IP" "$LAN_NET" "$HUB_NAME" >/dev/null 2>&1; then
      ok "Hub attached to LAN at $HUB_IP"
      MACVLAN_OK="true"
    elif [ "$HOST_TYPE" = "qnap" ]; then
      die "Could not attach Hub to the qnet network with a static IP from the CLI.
     In Container Station, attach the '$HUB_NAME' container to your qnet network and
     assign it a static IP (suggested: $HUB_IP). Then open http://$HUB_IP:$HUB_PORT"
    else
      lan_die "Could not attach Hub to '$LAN_NET' at $HUB_IP."
    fi
  fi
}

# Restart the host's avahi-daemon so it re-announces under the (just-changed) hostname.
# Best-effort: only acts if systemd + an active avahi-daemon are present.
restart_host_avahi() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl is-active --quiet avahi-daemon 2>/dev/null || return 0
  if $SUDO systemctl restart avahi-daemon >/dev/null 2>&1; then
    ok "Host avahi-daemon restarted"
  else
    warn "Could not restart host avahi-daemon (mDNS ownership may take a moment to settle)."
  fi
}

# Ensure EXACTLY ONE publisher owns securius-hub.local, decided by whether Hub got its
# macvlan/qnet LAN IP:
#   macvlan UP   -> the Hub CONTAINER must own the name (its macvlan IP is the only
#                   reachable path, since Docker disables the container's host-port
#                   publishing under macvlan). If the HOST is named securius-hub it would
#                   steal the name, so rename the host to securius-device + restart host
#                   avahi to yield it, then restart Hub so its avahi re-claims the freed
#                   name at the macvlan IP.
#   macvlan DOWN -> the HOST keeps securius-hub.local (host-port publishing works in this
#                   fallback), so leave everything; the container avahi harmlessly renames.
# Scope: only touches the hostname on standard Linux where WE set it to securius-hub (our
# dedicated image / Armbian build). On a NAS or a user's own box (hostname != securius-hub)
# the host never claims the name, so there is nothing to do and we NEVER rename their host.
configure_mdns_ownership() {
  info "Configuring mDNS ownership of ${HUB_HOSTNAME}.local (macvlan: ${MACVLAN_OK})"

  if [ "$MACVLAN_OK" != "true" ]; then
    # Bridge-only fallback: the HOST keeps securius-hub.local (host-port publishing works
    # here), and the Hub container (image ≥0.3.2, SECURIUS_MDNS=auto) detects it is
    # bridge-only and does NOT advertise — so there is no collision. Nothing to do.
    info "macvlan not active — host keeps ${HUB_HOSTNAME}.local (host-port path); container stays silent. No change."
    return 0
  fi

  # macvlan IS up: the Hub CONTAINER must own securius-hub.local at its LAN IP (Docker
  # disables the container's host-port publishing under macvlan, so the macvlan IP is the
  # only reachable path).
  #
  # 1) Make sure the HOST doesn't also claim the name. Only OUR dedicated standard-Linux
  #    image is named securius-hub; a NAS/user host is named something else and never
  #    claims it (so we NEVER rename a NAS or a user's box).
  if ! is_nas && command -v hostnamectl >/dev/null 2>&1; then
    cur="$( (hostnamectl --static 2>/dev/null || hostname 2>/dev/null) | head -n1 )"
    if [ "$cur" = "$HUB_HOSTNAME" ]; then
      info "Yielding ${HUB_HOSTNAME}.local from the host (renaming host to ${HOST_ALT_NAME})"
      if $SUDO hostnamectl set-hostname "$HOST_ALT_NAME" >/dev/null 2>&1; then
        ok "Host renamed to ${HOST_ALT_NAME}"
        if [ -f /etc/hosts ]; then
          $SUDO sed -i "s/\b${HUB_HOSTNAME}\b/${HOST_ALT_NAME}/g" /etc/hosts 2>/dev/null \
            && ok "Updated /etc/hosts (${HUB_HOSTNAME} -> ${HOST_ALT_NAME})" \
            || warn "Could not update /etc/hosts."
        fi
        restart_host_avahi
      else
        warn "Could not change the host hostname — ${HUB_HOSTNAME}.local may resolve to the (unreachable) host IP."
      fi
    else
      info "Host is '${cur:-unknown}' (not ${HUB_HOSTNAME}) — no collision; the Hub container will own ${HUB_HOSTNAME}.local."
    fi
  else
    info "NAS / no hostnamectl — not renaming the host; the Hub container owns ${HUB_HOSTNAME}.local on its LAN IP."
  fi

  # 2) Restart Hub so its entrypoint RE-DETECTS the macvlan interface (attached AFTER the
  #    initial container start) and brings avahi up to claim ${HUB_HOSTNAME}.local at the
  #    LAN IP. Required in BOTH the rename and the no-rename (NAS) cases. Networks + static
  #    IP are preserved across a restart; image ≥0.3.2 clears stale dbus state on start.
  if $DOCKER restart "$HUB_NAME" >/dev/null 2>&1; then
    ok "Hub restarted — its avahi now owns ${HUB_HOSTNAME}.local at ${HUB_IP}"
  else
    warn "Could not restart Hub to enable mDNS; it will enable on its next restart."
  fi
}

# The self-update sidecar. It recreates the Hub container on request (Hub can't replace
# its own running process). It needs ONLY the Docker socket + the shared channel volume —
# no ports, no LAN IP, no special network (identical on QNAP and standard Linux). Mirrors
# start_hub's re-run handling: skip if it already exists, just start it if it's stopped.
start_updater() {
  info "Pulling updater image (public, no login required)"
  $DOCKER pull "$UPDATER_IMAGE" >/dev/null || die "Failed to pull $UPDATER_IMAGE"
  ok "Image ready"

  if $DOCKER ps -a --format '{{.Names}}' | grep -qx "$UPDATER_NAME"; then
    warn "Container '$UPDATER_NAME' already exists — not recreating."
    [ "$($DOCKER inspect -f '{{.State.Running}}' "$UPDATER_NAME" 2>/dev/null)" = "true" ] \
      || { $DOCKER start "$UPDATER_NAME" >/dev/null && ok "Started existing '$UPDATER_NAME'"; }
  else
    info "Starting Hub updater sidecar"
    $DOCKER run -d \
      --name "$UPDATER_NAME" \
      --restart unless-stopped \
      --dns "$DNS_PRIMARY" \
      --dns "$DNS_FALLBACK" \
      -v "$HOST_SOCKET:$HOST_SOCKET" \
      -v "$CHANNEL_VOL:/channel" \
      "$UPDATER_IMAGE" >/dev/null \
      || die "Failed to start the updater container."
    ok "Updater sidecar started"
  fi
}

summary() {
  printf "\n%b\n" "${C_G}${C_B}Securius Hub is up.${C_0}"
  printf "  Open:      %bhttp://%s:%s%b\n" "$C_B" "$HUB_IP" "$HUB_PORT" "$C_0"
  printf "  LAN IP:    %s  (interface %s, gateway %s)\n" "$HUB_IP" "$IFACE" "$GATEWAY"
  printf "  Networks:  %s (LAN) + %s (internal)\n" "$LAN_NET" "$SUITE_NET"
  printf "  Updater:   %s installed — Hub can update itself from its UI\n" "$UPDATER_NAME"
  printf "\n"
  printf "  From here, install Shield and other products in the Hub UI. Any passwords\n"
  printf "  (e.g. your Pi-hole password) are entered there — never in this installer.\n"
  printf "\n"
  printf "  %bNote:%b open the URL from another device on your LAN (a phone, laptop, or\n" "$C_Y" "$C_0"
  printf "  over VPN). The machine you ran this on cannot reach Hub's own LAN IP — that's\n"
  printf "  a normal macvlan/qnet limitation, not a failure.\n\n"
}

main() {
  printf "%b\n\n" "${C_B}Securius Suite installer${C_0}"
  detect_host_type
  ensure_docker
  detect_lan
  pick_hub_ip
  create_suite_network
  create_lan_network
  ensure_channel_volume
  start_hub
  configure_mdns_ownership
  start_updater
  summary
}

main "$@"
