#!/bin/bash
#───────────────────────────────────────────────────────────────────────────────
#  install-swarm.sh – Traefik + Portainer em Docker Swarm (Debian/Ubuntu)
#───────────────────────────────────────────────────────────────────────────────
set -e

# ── Cores
GREEN='\e[32m'; YELLOW='\e[33m'; RED='\e[31m'; BLUE='\e[34m'; NC='\e[0m'

# ── Spinner
spinner(){ local pid=$1; local delay=0.1; local spin='|/-\'; while kill -0 $pid 2>/dev/null; do
  printf " [%c]  " "$spin"; spin=${spin#?}${spin%??}; sleep $delay; printf "\b\b\b\b\b\b";
done; printf "    \b\b\b\b"; }

# ── Requisitos mínimos (2 GB RAM / 10 GB disco)
check_system(){ echo -e "${BLUE}Verificando requisitos...${NC}";
  [ "$(df -BG / | awk 'NR==2{print $4}'|tr -d 'G')" -lt 10 ] && \
    { echo -e "${RED}❌ Espaço em disco insuficiente (10 GB+)${NC}"; exit 1; }
  [ "$(free -g | awk 'NR==2{print $2}')" -lt 2 ] && \
    { echo -e "${RED}❌ RAM insuficiente (2 GB+)${NC}"; exit 1; }
  echo -e "${GREEN}✅ Requisitos ok${NC}"; }

# ── Perguntas ao usuário
read_inputs(){
  echo -e "${YELLOW}📧 E-mail Let's Encrypt:${NC}"; read -r EMAIL
  echo -e "${YELLOW}🌐 Domínio do Traefik (ex.: traefik.exemplo.com):${NC}"; read -r TR_DOMAIN
  echo -e "${YELLOW}🔑 Senha básica do Traefik (formato user:$(openssl passwd -apr1)): ${NC}"; read -r TR_AUTH
  echo -e "${YELLOW}🌐 Domínio do Portainer (ex.: portainer.exemplo.com):${NC}"; read -r PT_DOMAIN
  echo -e "${YELLOW}🌐 Domínio do Edge (opcional, ex.: edge.exemplo.com):${NC}"; read -r EDGE_DOMAIN
  echo ""; echo -e "${GREEN}Confirme [y/N]:${NC}"; read -r CONFIRM
  [[ "${CONFIRM,,}" != "y" ]] && { echo -e "${RED}Cancelado.${NC}"; exit 0; } }

# ── Instala Docker
install_docker(){
  echo -e "${BLUE}Instalando Docker...${NC}";
  (apt update -y && apt upgrade -y && \
   apt install -y curl ca-certificates gnupg lsb-release >/dev/null && \
   curl -fsSL https://get.docker.com | sh) & spinner $!; }

# ── Inicializa Swarm (se ainda não)
init_swarm(){
  if docker info --format '{{.Swarm.LocalNodeState}}' | grep -q inactive; then
     local IP=$(hostname -I | awk '{print $1}')
     docker swarm init --advertise-addr "$IP"
     echo -e "${GREEN}✅ Swarm iniciado (manager: $IP)${NC}"
  else
     echo -e "${GREEN}🌀 Swarm já ativo${NC}"
  fi
}

# ── Cria rede overlay & volumes persistentes
prepare_storage(){
  docker network ls | grep -q proxy_net || \
    docker network create --driver overlay --attachable proxy_net
  docker volume ls   | grep -q portainer_data || \
    docker volume create portainer_data
  mkdir -p /opt/traefik && touch /opt/traefik/acme.json && chmod 600 /opt/traefik/acme.json
}

# ── Gera stack.yml
generate_stack(){
cat >/root/stack.yml <<EOF
version: "3.9"
networks:
  proxy_net:
    external: true

services:
  traefik:
    image: traefik:latest
    command:
      - "--providers.docker.swarmMode=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--api.dashboard=true"
      - "--log.level=ERROR"
      - "--certificatesresolvers.leresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.leresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.leresolver.acme.email=${EMAIL}"
      - "--certificatesresolvers.leresolver.acme.storage=/data/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "/opt/traefik:/data"
    networks:
      - proxy_net
    deploy:
      placement:
        constraints: [node.role == manager]
      labels:
        - "traefik.http.routers.http-catchall.rule=hostregexp(\`{host:.+}\`)"
        - "traefik.http.routers.http-catchall.entrypoints=web"
        - "traefik.http.routers.http-catchall.middlewares=redirect-to-https"
        - "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
        - "traefik.http.routers.traefik-dashboard.rule=Host(\`${TR_DOMAIN}\`)"
        - "traefik.http.routers.traefik-dashboard.entrypoints=websecure"
        - "traefik.http.routers.traefik-dashboard.service=api@internal"
        - "traefik.http.routers.traefik-dashboard.tls.certresolver=leresolver"
        - "traefik.http.routers.traefik-dashboard.middlewares=traefik-auth"
        - "traefik.http.middlewares.traefik-auth.basicauth.users=${TR_AUTH}"

  portainer:
    image: portainer/portainer-ce:latest
    command: -H unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks:
      - proxy_net
    deploy:
      replicas: 1
      placement:
        constraints: [node.role == manager]
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.frontend.rule=Host(\`${PT_DOMAIN}\`)"
        - "traefik.http.routers.frontend.entrypoints=websecure"
        - "traefik.http.routers.frontend.service=frontend"
        - "traefik.http.routers.frontend.tls.certresolver=leresolver"
        - "traefik.http.services.frontend.loadbalancer.server.port=9000"
        - "traefik.http.routers.edge.rule=Host(\`${EDGE_DOMAIN}\`)"
        - "traefik.http.routers.edge.entrypoints=websecure"
        - "traefik.http.routers.edge.service=edge"
        - "traefik.http.routers.edge.tls.certresolver=leresolver"
        - "traefik.http.services.edge.loadbalancer.server.port=8000"

volumes:
  portainer_data:
    external: true
EOF
echo -e "${GREEN}✅ stack.yml criado em /root/stack.yml${NC}"
}

# ── Faz o deploy
deploy_stack(){
  echo -e "${BLUE}🚀 Fazendo deploy da stack...${NC}"
  docker stack deploy -c /root/stack.yml core
  echo -e "${GREEN}✅ Stack 'core' ativa. Verifique com: docker stack services core${NC}"
}

# ── FLOW
check_system
read_inputs
install_docker
init_swarm
prepare_storage
generate_stack
deploy_stack

echo -e "${GREEN}
────────────────────────────────────────────────────────────────
Portainer ➜ https://${PT_DOMAIN}
Traefik   ➜ https://${TR_DOMAIN}
────────────────────────────────────────────────────────────────${NC}"
