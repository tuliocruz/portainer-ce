#!/usr/bin/env bash
# install.sh - Debian 12: Docker Engine + Swarm + Portainer CE (versões fixas) via stack
# Execução:
#   sudo ./install.sh
# Reexecutável com segurança (idempotente).

set -euo pipefail

############################################
#               CONFIGURÁVEIS             #
############################################
PORTAINER_VERSION="${PORTAINER_VERSION:-2.32.0}"  # Versão fixa do Portainer CE
AGENT_VERSION="${AGENT_VERSION:-2.32.0}"          # Versão fixa do Portainer Agent
EXPOSE_TUNNEL="${EXPOSE_TUNNEL:-true}"            # true = expõe porta 8000 (túnel/Edge)
ADD_USER_TO_DOCKER="${ADD_USER_TO_DOCKER:-false}" # true = adiciona usuário atual ao grupo docker
STACK_NAME="${STACK_NAME:-portainer}"
STACK_DIR="${STACK_DIR:-/opt/portainer}"
COMPOSE_FILE="${COMPOSE_FILE:-${STACK_DIR}/portainer-agent-stack.yml}"
DEBIAN_CODENAME="bookworm"

############################################
#             FUNÇÕES AUXILIARES          #
############################################
log()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Comando obrigatório não encontrado: $1"; exit 1; }
}

require_root_or_sudo() {
  if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      err "Execute como root ou instale 'sudo' (su -c 'apt-get update && apt-get install -y sudo')."
      exit 1
    fi
  fi
}

as_root() {
  if [[ $EUID -ne 0 ]]; then sudo bash -c "$*"; else bash -c "$*"; fi
}

first_ipv4() {
  # pega o primeiro IPv4 não-loopback
  ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./ && $i ~ /^[0-9.]+$/) {print $i; exit}}')
  if [[ -z "${ip:-}" ]]; then
    # fallback: ip route
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  fi
  echo "${ip:-127.0.0.1}"
}

ensure_dir() {
  [[ -d "$1" ]] || as_root "mkdir -p '$1'"
}

apt_install() {
  as_root "apt-get update -y"
  as_root "DEBIAN_FRONTEND=noninteractive apt-get install -y $*"
}

############################################
#        1) INSTALAR DOCKER ENGINE        #
############################################
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker já está instalado. Pulando instalação do Engine."
    return
  fi

  log "Instalando dependências..."
  apt_install ca-certificates curl gnupg lsb-release

  log "Adicionando chave GPG do Docker e repositório oficial..."
  as_root "install -m 0755 -d /etc/apt/keyrings"
  curl -fsSL https://download.docker.com/linux/debian/gpg | as_root "gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  as_root "chmod a+r /etc/apt/keyrings/docker.gpg"

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DEBIAN_CODENAME} stable" \
    | as_root "tee /etc/apt/sources.list.d/docker.list >/dev/null"

  log "Instalando pacotes do Docker Engine..."
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  log "Habilitando e iniciando serviço docker..."
  as_root "systemctl enable --now docker"

  if [[ "${ADD_USER_TO_DOCKER}" == "true" ]]; then
    current_user="${SUDO_USER:-$USER}"
    if id -nG "$current_user" 2>/dev/null | grep -qw docker; then
      log "Usuário '$current_user' já está no grupo docker."
    else
      log "Adicionando '$current_user' ao grupo docker (efetivo após novo login)."
      as_root "usermod -aG docker '$current_user' || true"
    fi
  fi

  log "Docker Engine instalado com sucesso."
}

############################################
#        2) INICIALIZAR DOCKER SWARM      #
############################################
init_swarm() {
  local state
  state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")
  if [[ "$state" == "active" ]]; then
    log "Docker Swarm já está ativo."
    return
  fi

  local ip
  ip="$(first_ipv4)"
  if [[ "$ip" == "127.0.0.1" ]]; then
    warn "Não foi possível detectar um IPv4 não-loopback; usando 127.0.0.1."
  fi

  log "Inicializando Docker Swarm (advertise-addr: $ip)..."
  as_root "docker swarm init --advertise-addr '${ip}'"
  log "Swarm inicializado."
}

############################################
#   3) ESCREVER COMPOSE E DEPLOY STACK    #
############################################
write_compose() {
  ensure_dir "$STACK_DIR"

  log "Gerando arquivo de stack: ${COMPOSE_FILE}"
  cat > "${COMPOSE_FILE}.tmp" <<YAML
version: "3.8"

services:
  portainer:
    image: portainer/portainer-ce:${PORTAINER_VERSION}
    ports:
      - "9443:9443"
YAML

  if [[ "${EXPOSE_TUNNEL}" == "true" ]]; then
    cat >> "${COMPOSE_FILE}.tmp" <<'YAML'
      - "8000:8000"
YAML
  fi

  cat >> "${COMPOSE_FILE}.tmp" <<'YAML'
    volumes:
      - portainer_data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
    command: >
      -H tcp://tasks.agent:9001
      --tlsskipverify
    networks:
      - portainer_agent_network

  agent:
    image: portainer/agent:__AGENT_VERSION__
    environment:
      AGENT_CLUSTER_ADDR: tasks.agent
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - portainer_agent_network
    deploy:
      mode: global
      placement:
        constraints:
          - node.platform.os == linux

networks:
  portainer_agent_network:
    driver: overlay

volumes:
  portainer_data:
    driver: local
YAML

  # substitui placeholder da versão do agente
  sed -i "s/__AGENT_VERSION__/${AGENT_VERSION}/g" "${COMPOSE_FILE}.tmp"
  as_root "mv -f '${COMPOSE_FILE}.tmp' '${COMPOSE_FILE}'"
}

deploy_stack() {
  log "Fazendo deploy da stack '${STACK_NAME}'..."
  as_root "docker stack deploy -c '${COMPOSE_FILE}' '${STACK_NAME}'"
  log "Stack enviada. Aguardando serviços subirem..."
  sleep 3
  as_root "docker stack services '${STACK_NAME}' || true"
}

show_summary() {
  local ip; ip="$(first_ipv4)"
  echo
  echo "=============================================="
  echo "✅ Instalação concluída."
  echo "▶ Swarm: $(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo '-')"
  echo "▶ Stack: ${STACK_NAME}"
  echo "▶ Compose: ${COMPOSE_FILE}"
  echo "▶ Portainer CE: ${PORTAINER_VERSION}"
  echo "▶ Agent: ${AGENT_VERSION}"
  echo "▶ UI: https://${ip}:9443"
  [[ "${EXPOSE_TUNNEL}" == "true" ]] && echo "▶ Tunnel (Edge): ${ip}:8000"
  echo "Para ver tarefas: sudo docker stack ps ${STACK_NAME}"
  echo "=============================================="
  echo
  warn "Se acessar a UI pela primeira vez, aceite o certificado autoassinado e crie o usuário administrador."
}

############################################
#          4) FIREWALL (OPCIONAL)         #
############################################
maybe_firewall_hint() {
  # Apenas dica: não vamos mexer em nftables/ufw automaticamente.
  cat <<'EOF'

[Nota sobre portas/firewall]
Se você usa firewall, garanta as portas abertas:
- Portainer UI: 9443/tcp (e 8000/tcp se EXPOSE_TUNNEL=true)
- Swarm cluster:
  * 2377/tcp (controle)
  * 7946/tcp e 7946/udp (membros)
  * 4789/udp (rede overlay)

EOF
}

############################################
#                EXECUÇÃO                 #
############################################
main() {
  require_root_or_sudo
  need_cmd awk
  need_cmd curl
  need_cmd grep
  need_cmd sed

  install_docker
  init_swarm
  write_compose
  deploy_stack
  maybe_firewall_hint
  show_summary
}

main "$@"
