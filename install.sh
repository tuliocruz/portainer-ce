#!/usr/bin/env bash
# Debian 12 (Bookworm) - Installer interativo
# Swarm + Traefik (TLS/LE, dashboard com BasicAuth) + Portainer CE/Agent (versões fixas)
# Perguntas: e-mail, domínios (traefik/portainer/edge) e senha do dashboard Traefik
set -Eeuo pipefail

# ===================== Cores/UX =====================
GREEN='\e[32m'; YELLOW='\e[33m'; RED='\e[31m'; BLUE='\e[34m'; NC='\e[0m'
spinner(){ local pid=$1 delay=0.1 spin='|/-\'; while kill -0 "$pid" 2>/dev/null; do for i in $(seq 0 3); do printf " [%c] " "${spin:$i:1}"; sleep $delay; printf "\b\b\b\b\b"; done; done; printf "     \b\b\b\b\b"; }
logo(){ clear; echo -e "${GREEN}
  _____        _____ _  __  _________     _______  ______ ____   ____ _______ 
 |  __ \ /\   / ____| |/ / |__   __\ \   / /  __ \|  ____|  _ \ / __ \__   __|
 | |__) /  \ | |    | ' /     | |   \ \_/ /| |__) | |__  | |_) | |  | | | |   
 |  ___/ /\ \| |    |  <      | |    \   / |  ___/|  __| |  _ <| |  | | | |   
 | |  / ____ \ |____| . \     | |     | |  | |    | |____| |_) | |__| | | |   
 |_| /_/    \_\_____|_|\_\    |_|     |_|  |_|    |______|____/ \____/  |_|   
${NC}"; }
step(){ local c=$1 t=5 p=$((c*100/t)) f=$((p/2)); echo -ne "${GREEN}Passo ${YELLOW}$c/$t ${GREEN}["; for ((i=0;i<50;i++)); do [[ $i -lt $f ]] && echo -n "=" || echo -n " "; done; echo -e "] ${p}%${NC}"; }

# ===================== Versões =====================
PORTAINER_VERSION="${PORTAINER_VERSION:-2.32.0}"
AGENT_VERSION="${AGENT_VERSION:-2.32.0}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.5.0}"

# ===================== Helpers =====================
has(){ command -v "$1" >/dev/null 2>&1; }
as_root(){ if [[ $EUID -ne 0 ]]; then sudo bash -c "$*"; else bash -c "$*"; fi; }
ipv4(){ local ip; ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./ && $i ~ /^[0-9.]+$/) {print $i; exit}}'); [[ -n "${ip:-}" ]] && { echo "$ip"; return; }; ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'); echo "${ip:-127.0.0.1}"; }
dhcp_in_use(){ pgrep -x dhclient >/dev/null 2>&1 && return 0; grep -RqsE 'iface\s+.+\s+inet\s+dhcp' /etc/network/interfaces* 2>/dev/null && return 0; grep -Rqs 'DHCP=yes' /etc/systemd/network 2>/dev/null && return 0; return 1; }

# ===================== 0) UI & Inputs =====================
logo
echo -e "${GREEN}=============================================================================="
echo -e "=                 ${YELLOW}Preencha as informações solicitadas abaixo${GREEN}                 ="
echo -e "==============================================================================${NC}\n"

step 1; read -rp "📧 E-mail para Let's Encrypt: " EMAIL
step 2; read -rp "🌐 Domínio do Traefik (ex: traefik.seudominio.com): " TRAEFIK_DOMAIN
step 3; read -rsp "🔑 Senha do Traefik (dashboard BasicAuth): " TRAEFIK_PASS; echo
step 4; read -rp "🌐 Domínio do Portainer (ex: portainer.seudominio.com): " PORTAINER_DOMAIN
step 5; read -rp "🌐 Domínio do Edge (ex: edge.seudominio.com): " EDGE_DOMAIN
echo

clear
echo -e "${BLUE}📋 Resumo das Informações${NC}"
echo -e "${GREEN}================================${NC}"
echo -e "📧 E-mail LE: ${YELLOW}${EMAIL}${NC}"
echo -e "🌐 Traefik: ${YELLOW}${TRAEFIK_DOMAIN}${NC}"
echo -e "🔑 Traefik (senha): ${YELLOW}********${NC}"
echo -e "🌐 Portainer: ${YELLOW}${PORTAINER_DOMAIN}${NC}"
echo -e "🌐 Edge: ${YELLOW}${EDGE_DOMAIN}${NC}"
echo -e "${GREEN}================================${NC}\n"
read -rp "As informações estão corretas? (y/n): " OK
[[ "${OK,,}" != "y" ]] && { echo -e "${RED}❌ Instalação cancelada.${NC}"; exit 0; }

# ===================== 1) Pré-checagens =====================
echo -e "${BLUE}Verificando requisitos do sistema...${NC}"
# Espaço
FREE_GB=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
[[ $FREE_GB -lt 5 ]] && { echo -e "${RED}❌ Espaço insuficiente (<5GB).${NC}"; exit 1; }
# Memória
TOTAL_RAM_GB=$(free -g | awk 'NR==2{print $2}')
[[ $TOTAL_RAM_GB -lt 1 ]] && { echo -e "${RED}❌ RAM insuficiente (<1GB).${NC}"; exit 1; }
echo -e "${GREEN}✅ Requisitos OK${NC}"

# ===================== 2) Limpeza leve (opcional, segura) =====================
echo -e "${YELLOW}Deseja limpar pacotes não essenciais antes? (recomendado) [Y/n]${NC}"
read -r DO_CLEAN; DO_CLEAN=${DO_CLEAN:-Y}
if [[ "${DO_CLEAN,,}" == "y" ]]; then
  echo -e "${YELLOW}🧹 Limpando pacotes não essenciais...${NC}"
  PKGS="apt-listchanges console-setup console-setup-linux debconf-i18n dictionaries-common iamerican ibritish keyboard-configuration \
libx11-6 libx11-data libxext6 libxmuu1 mailcap manpages mime-support nano \
python3-apt python3-certifi python3-chardet python3-charset-normalizer python3-debconf python3-debian python3-debianbts \
python3-httplib2 python3-idna python3-pkg-resources python3-pycurl python3-pyparsing python3-pysimplesoap python3-reportbug \
python3-requests python3-six python3-urllib3 reportbug task-english tasksel tasksel-data vim-common vim-tiny xauth"
  if ! dhcp_in_use; then PKGS="$PKGS isc-dhcp-client isc-dhcp-common"; echo "[INFO] DHCP não detectado -> isc-dhcp-* será removido."; else echo "[INFO] DHCP detectado -> preservando isc-dhcp-*."; fi
  (as_root "apt-get update -y && apt-get remove --purge -y $PKGS || true && apt-get autoremove --purge -y && apt-get clean && apt-get autoclean") >/dev/null 2>&1 &
  spinner $!
  as_root "rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* /usr/share/man/* /usr/share/info/*" || true
  echo -e "${GREEN}✅ Limpeza concluída${NC}"
fi

# ===================== 3) Docker Engine =====================
if ! has docker; then
  echo -e "${YELLOW}🐳 Instalando Docker Engine (repo oficial)...${NC}"
  (as_root "apt-get update -y && apt-get install -y ca-certificates curl gnupg lsb-release && \
   install -m 0755 -d /etc/apt/keyrings && \
   curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor | tee /tmp/docker.gpg >/dev/null && \
   mv /tmp/docker.gpg /etc/apt/keyrings/docker.gpg && chmod a+r /etc/apt/keyrings/docker.gpg && \
   echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable\" > /etc/apt/sources.list.d/docker.list && \
   apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && \
   systemctl enable --now docker") >/dev/null 2>&1 &
  spinner $!
else
  echo -e "${GREEN}✅ Docker já instalado${NC}"
fi

# ===================== 4) Swarm init =====================
IP=$(ipv4)
SWARM_STATE=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")
if [[ "$SWARM_STATE" != "active" ]]; then
  echo -e "${YELLOW}🕸️  Inicializando Docker Swarm (advertise-addr ${IP})...${NC}"
  as_root "docker swarm init --advertise-addr '${IP}'"
else
  echo -e "${GREEN}✅ Swarm já ativo${NC}"
fi

# ===================== 5) Preparos (hash da senha, rede/volumes) =====================
# Hash BasicAuth (formato apr1 para Traefik)
if ! has openssl; then as_root "apt-get update -y && apt-get install -y openssl" >/dev/null 2>&1; fi
TRAEFIK_USER="admin"
TRAEFIK_HASH=$(openssl passwd -apr1 "${TRAEFIK_PASS}")
# Rede overlay para Traefik/Portainer
STACK_NAME="infra"
STACK_DIR="/opt/${STACK_NAME}"
as_root "mkdir -p '${STACK_DIR}'"

# ===================== 6) Stack YAML (Traefik + Portainer CE/Agent) =====================
# Observações:
# - Traefik com swarmMode, exposedByDefault=false, dashboard com BasicAuth e Let's Encrypt (HTTP-01)
# - serversTransport.insecureSkipVerify=true para falar com Portainer (9443, self-signed)
# - Portainer CE via Agent (global). UI roteada por Traefik nos domínios fornecidos.
# - Sem publicar 9443/8000 externamente; tudo passa pelo Traefik.
cat > "/tmp/${STACK_NAME}.yml" <<YAML
version: "3.8"

networks:
  proxy:
    driver: overlay
    attachable: true

volumes:
  traefik_letsencrypt:
    driver: local
  portainer_data:
    driver: local

services:
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    command:
      - --global.checknewversion=false
      - --log.level=ERROR
      - --accesslog=false
      - --api.dashboard=true
      - --serversTransport.insecureSkipVerify=true
      - --providers.docker=true
      - --providers.docker.swarmMode=true
      - --providers.docker.endpoint=unix:///var/run/docker.sock
      - --providers.docker.exposedByDefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entryPoint.to=websecure
      - --certificatesresolvers.leresolver.acme.email=${EMAIL}
      - --certificatesresolvers.leresolver.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.leresolver.acme.httpchallenge=true
      - --certificatesresolvers.leresolver.acme.httpchallenge.entrypoint=web
    ports:
      - target: 80
        published: 80
        mode: ingress
      - target: 443
        published: 443
        mode: ingress
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_letsencrypt:/letsencrypt
    networks:
      - proxy
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        # dashboard protegido por BasicAuth
        - "traefik.http.routers.traefik.rule=Host(\`${TRAEFIK_DOMAIN}\`)"
        - "traefik.http.routers.traefik.entrypoints=websecure"
        - "traefik.http.routers.traefik.tls.certresolver=leresolver"
        - "traefik.http.routers.traefik.service=api@internal"
        - "traefik.http.middlewares.traefik-auth.basicauth.users=${TRAEFIK_USER}:${TRAEFIK_HASH}"
        - "traefik.http.routers.traefik.middlewares=traefik-auth"

  agent:
    image: portainer/agent:${AGENT_VERSION}
    environment:
      AGENT_CLUSTER_ADDR: tasks.agent
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - proxy
    deploy:
      mode: global
      placement:
        constraints:
          - node.platform.os == linux
        # Em clusters multi-nó, o Agent rodará em todos

  portainer:
    image: portainer/portainer-ce:${PORTAINER_VERSION}
    command: >
      -H tcp://tasks.agent:9001
      --tlsskipverify
    volumes:
      - portainer_data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - proxy
    deploy:
      mode: replicated
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        # Rota da UI Portainer (backend HTTPS 9443; skipVerify global)
        - "traefik.http.routers.portainer.rule=Host(\`${PORTAINER_DOMAIN}\`)"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.tls.certresolver=leresolver"
        - "traefik.http.services.portainer.loadbalancer.server.port=9443"
        - "traefik.http.services.portainer.loadbalancer.server.scheme=https"
        # Rota Edge (túnel) - mesma service, porta 8000
        - "traefik.http.routers.edge.rule=Host(\`${EDGE_DOMAIN}\`)"
        - "traefik.http.routers.edge.entrypoints=websecure"
        - "traefik.http.routers.edge.tls.certresolver=leresolver"
        - "traefik.http.services.edge.loadbalancer.server.port=8000"
YAML

# garantir permissão para acme.json dentro do volume (Traefik cria se não existir)
as_root "docker volume create traefik_letsencrypt >/dev/null 2>&1 || true"

# ===================== 7) Deploy =====================
echo -e "${YELLOW}🚀 Fazendo deploy da stack 'infra' (Traefik + Portainer)...${NC}"
(as_root "docker stack deploy -c /tmp/${STACK_NAME}.yml ${STACK_NAME}") >/dev/null 2>&1 & spinner $!

# ===================== 8) Verificação =====================
echo -e "${BLUE}Verificando serviços...${NC}"
as_root "docker stack services ${STACK_NAME}"
echo

# ===================== 9) Dicas/Firewall =====================
echo -e "${YELLOW}Se usar firewall, abra as portas:${NC}
- 80/tcp e 443/tcp (Traefik)
- Swarm entre nós: 2377/tcp, 7946/tcp+udp, 4789/udp
"

# ===================== 10) Sumário =====================
HOST_IP=$(ipv4)
echo -e "${GREEN}================================${NC}"
echo -e "✅  Deploy concluído."
echo -e "🔐 Traefik Dashboard: https://${TRAEFIK_DOMAIN}"
echo -e "   Usuário: admin | Senha: (a que você digitou)"
echo -e "🛠  Portainer UI:     https://${PORTAINER_DOMAIN}"
echo -e "🔌 Portainer Edge:    https://${EDGE_DOMAIN}"
echo -e "${GREEN}================================${NC}"
echo -e "Comandos úteis:"
echo -e "  docker stack ps ${STACK_NAME}"
echo -e "  docker service logs ${STACK_NAME}_traefik -f"
echo -e "  docker service logs ${STACK_NAME}_portainer -f"
