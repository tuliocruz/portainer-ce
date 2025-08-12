#!/usr/bin/env bash

set -euo pipefail

# ---- util ----
RED="$(printf '\033[31m')"; GREEN="$(printf '\033[32m')"; YELLOW="$(printf '\033[33m')"; BLUE="$(printf '\033[34m')"; RESET="$(printf '\033[0m')"
log(){ echo -e "${BLUE}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERRO]${RESET} $*" >&2; }
die(){ err "$*"; exit 1; }

confirm(){ # confirm "Pergunta?" default_yes|default_no
  local prompt="$1" def="${2:-default_yes}" ans
  case "$def" in
    default_yes) read -r -p "$prompt [S/n]: " ans || true; [[ -z "${ans:-}" || "${ans,,}" =~ ^s|^y ]];;
    default_no)  read -r -p "$prompt [s/N]: " ans || true; [[ "${ans,,}" =~ ^s|^y ]];;
    *)           read -r -p "$prompt [s/n]: " ans || true; [[ "${ans,,}" =~ ^s|^y ]];;
  esac
}

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Execute como root ou instale 'sudo'."
    exec sudo -E bash "$0" "$@"
  fi
}

detect_os(){
  . /etc/os-release || true
  if [ "${ID:-}" != "debian" ] || [ "${VERSION_CODENAME:-}" != "bookworm" ]; then
    warn "Detectado ID=${ID:-?} CODENAME=${VERSION_CODENAME:-?}. Script foi testado para Debian 12 (bookworm)."
    confirm "Deseja continuar mesmo assim?" default_no || die "Abortado."
  fi
}

detect_ipv4(){
  ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}'
}

ensure_packages(){
  export DEBIAN_FRONTEND=noninteractive
  log "Atualizando pacotes base..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release iproute2
}

setup_docker_repo(){
  log "Configurando repositório oficial do Docker..."
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local codename arch
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"
  arch="$(dpkg --print-architecture)"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
}

install_docker(){
  log "Instalando Docker Engine, CLI, containerd, buildx e compose plugin..."
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker instalado e ativo."
}

tune_network(){
  log "Aplicando ip_forward para redes overlay do Swarm..."
  cat >/etc/sysctl.d/99-docker-swarm.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl --system >/dev/null
}

add_user_group(){
  if [ -n "${SUDO_USER:-}" ] && id "${SUDO_USER}" >/dev/null 2>&1; then
    log "Adicionando '${SUDO_USER}' ao grupo docker..."
    groupadd -f docker
    usermod -aG docker "${SUDO_USER}"
  fi
}

configure_ufw(){
  local ENABLE_UFW="${ENABLE_UFW:-}"
  if ! command -v ufw >/dev/null 2>&1; then
    warn "UFW não encontrado. Pulando firewall."
    return 0
  fi
  local status; status="$(ufw status | head -n1 || true)"
  if ! echo "$status" | grep -qi "Status: active"; then
    warn "UFW não está ativo. Pulando firewall."
    return 0
  fi
  if [ -z "$ENABLE_UFW" ]; then
    confirm "UFW ativo detectado. Abrir portas do Swarm automaticamente (2377/tcp, 7946/tcp+udp, 4789/udp)?" default_yes \
      && ENABLE_UFW="yes" || ENABLE_UFW="no"
  fi
  [ "$ENABLE_UFW" = "yes" ] || { warn "Mantendo UFW inalterado."; return 0; }

  log "Abrindo portas do Docker Swarm no UFW..."
  ufw allow 2377/tcp || true   # Manager API
  ufw allow 7946/tcp || true   # Comunicação entre nós
  ufw allow 7946/udp || true
  ufw allow 4789/udp || true   # Overlay/VXLAN
}

init_or_join_swarm(){
  local mode="${SWARM_MODE:-}"
  local state; state="$(docker info --format '{{.Swarm.LocalNodeState}}' || echo 'unknown')"

  if [ -z "$mode" ]; then
    echo
    echo "Configuração do Swarm:"
    echo "  1) Iniciar novo cluster neste servidor (manager)"
    echo "  2) Ingressar como worker em cluster existente"
    echo "  3) Ingressar como manager adicional"
    echo "  4) Pular configuração do Swarm agora"
    read -r -p "Escolha [1-4]: " choice || true
    case "${choice:-1}" in
      1) mode="init" ;;
      2) mode="join-worker" ;;
      3) mode="join-manager" ;;
      4) mode="none" ;;
      *) mode="init" ;;
    esac
  fi

  case "$mode" in
    init)
      if [ "$state" = "active" ]; then
        ok "Swarm já está ativo neste nó."
      else
        local ip="${ADVERTISE_ADDR:-}"
        [ -z "$ip" ] && ip="$(detect_ipv4 || true)"
        read -r -p "Endereço IP para --advertise-addr [${ip:-digite}]: " tmp || true
        ip="${tmp:-$ip}"
        [ -z "$ip" ] && die "Informe um IP para --advertise-addr."
        log "Iniciando Swarm (manager) com advertise-addr ${ip}..."
        docker swarm init --advertise-addr "$ip" || die "Falha ao iniciar o Swarm."
      fi
      ;;
    join-worker|join-manager)
      local maddr="${MANAGER_ADDR:-}" token="${JOIN_TOKEN:-}"
      [ -z "$maddr" ] && read -r -p "Endereço do manager (ex: 1.2.3.4:2377): " maddr
      [ -z "$token" ] && read -r -p "Token (${mode#join-}): " token
      [ -z "$maddr" ] && die "MANAGER_ADDR é obrigatório."
      [ -z "$token" ] && die "JOIN_TOKEN é obrigatório."
      log "Ingressando no cluster (${mode})..."
      docker swarm join --token "$token" "$maddr" || die "Falha ao ingressar. Verifique token/endpoint."
      ;;
    none)
      warn "Pulando configuração do Swarm conforme solicitado."
      ;;
    *)
      die "SWARM_MODE inválido: $mode"
      ;;
  esac
}

main(){
  echo "============================================================"
  echo "  Instalador Docker + Compose + Swarm"
  echo "============================================================"
  need_root "$@"
  detect_os
  ensure_packages
  setup_docker_repo
  install_docker
  tune_network
  add_user_group
  configure_ufw
  init_or_join_swarm
  echo
  ok "Pronto! Docker + Swarm instalado."
  echo " - Se você foi adicionado ao grupo 'docker', faça logout/login para aplicar."
  echo " - Verifique: 'docker --version', 'docker compose version' e 'docker info | grep -A3 Swarm'."
}

main "$@"
