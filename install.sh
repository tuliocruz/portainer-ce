#!/bin/bash

# Opções de segurança e erros
set -eo pipefail

# Cores
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
BLUE='\e[34m'
NC='\e[0m'

# Função spinner
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "      \b\b\b\b\b\b"
}

# Verificar requisitos
check_system_requirements() {
    echo -e "${BLUE}Verificando requisitos do sistema...${NC}"
    command -v docker >/dev/null 2>&1 || { echo -e "${RED}❌ Docker não encontrado.${NC}"; return 1; }
    command -v docker compose >/dev/null 2>&1 || { echo -e "${RED}❌ 'docker compose' não encontrado.${NC}"; return 1; }
    local free_space=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "${free_space:-0}" -lt 3 ]; then
        echo -e "${RED}❌ Espaço em disco insuficiente. Precisa de pelo menos 3GB.${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ Requisitos do sistema atendidos${NC}"
    return 0
}

# Logo animado
show_animated_logo() {
    clear
    echo -e "${GREEN}"
    echo -e "  _____        _____ _  __  _________     _______  ______ ____   ____ _______ "
    echo -e " |  __ \ /\   / ____| |/ / |__   __\ \   / /  __ \|  ____|  _ \ / __ \__   __|"
    echo -e " | |__) /  \ | |    | ' /     | |   \ \_/ /| |__) | |__  | |_) | |  | | | |   "
    echo -e " |  ___/ /\ \| |    |  <      | |    \   / |  ___/|  __| |  _ <| |  | | | |   "
    echo -e " | |  / ____ \ |____| . \     | |     | |  | |    | |____| |_) | |__| | | |   "
    echo -e " |_| /_/    \_\_____|_|\_\    |_|     |_|  |_|    |______|____/ \____/  |_|   "
    echo -e "${NC}"
    sleep 1
}

# Banner
show_banner() {
    echo -e "${GREEN}=============================================================================="
    echo -e "=                                                                            ="
    echo -e "=                 ${YELLOW}Preencha as informações solicitadas abaixo${GREEN}                 ="
    echo -e "=                                                                            ="
    echo -e "==============================================================================${NC}"
}

# Barra de progresso
show_step() {
    local current="${1:-0}"
    local total="${2:-6}"
    local percent=$((current * 100 / total))
    local completed=$((percent / 2))
    echo -ne "${GREEN}Passo ${YELLOW}${current}/${total} ${GREEN}["
    for ((i=0; i<50; i++)); do
        if [ $i -lt $completed ]; then echo -ne "="; else echo -ne " "; fi
    done
    echo -e "] ${percent}%${NC}"
}

# Gerar hash htpasswd
make_htpasswd() {
    local user="$1"
    local pass="$2"
    printf "%s:%s" "$user" "$(printf "%s" "$pass" | openssl passwd -apr1 -stdin)"
}

# === Fluxo ===
clear
show_animated_logo
show_banner
echo ""

show_step 1
read -p "📧 Endereço de e-mail (Let's Encrypt): " email
echo ""

show_step 2
read -p "🌐 Domínio do Traefik (ex: traefik.seudominio.com): " traefik
echo ""

show_step 3
read -p "👤 Usuário do Dashboard [admin]: " dash_user
dash_user=${dash_user:-admin}
read -s -p "🔑 Senha do Dashboard: " dash_pass
echo ""

show_step 4
read -p "🌐 Domínio do Portainer (ex: portainer.seudominio.com): " portainer
echo ""

show_step 5
read -p "🌐 Domínio do Edge (opcional): " edge
echo ""

show_step 6
echo -e "${BLUE}📋 Resumo:${NC}"
echo -e "📧 E-mail: ${YELLOW}${email}${NC}"
echo -e "🌐 Traefik: ${YELLOW}${traefik}${NC}"
echo -e "👤 Dashboard user: ${YELLOW}${dash_user}${NC}"
echo -e "🌐 Portainer: ${YELLOW}${portainer}${NC}"
[ -n "$edge" ] && echo -e "🌐 Edge: ${YELLOW}${edge}${NC}"
read -p "As informações estão corretas? (y/n): " confirma
[ "${confirma,,}" = "y" ] || { echo -e "${RED}❌ Cancelado.${NC}"; exit 1; }

clear
check_system_requirements || exit 1

mkdir -p ~/Portainer && cd ~/Portainer

# Criar docker-compose.yml
htline="$(make_htpasswd "$dash_user" "$dash_pass")"

cat > docker-compose.yml <<EOL
version: "3.8"

services:
  traefik:
    image: traefik:2.11
    container_name: traefik
    restart: always
    command:
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --api.dashboard=true
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --log.level=ERROR
      - --certificatesresolvers.le.acme.email=${email}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "traefik_letsencrypt:/letsencrypt"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.http-catchall.rule=HostRegexp(\`{host:.+}\`)"
      - "traefik.http.routers.http-catchall.entrypoints=web"
      - "traefik.http.routers.http-catchall.middlewares=redirect-to-https"
      - "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
      - "traefik.http.routers.traefik.rule=Host(\`${traefik}\`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=le"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.middlewares.traefik-auth.basicauth.users=${htline}"
      - "traefik.http.routers.traefik.middlewares=traefik-auth"

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    command: -H unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(\`${portainer}\`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=le"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"
    ports:
      - "8000:8000"

volumes:
  traefik_letsencrypt:
  portainer_data:
EOL

# Preparar volume ACME
docker volume inspect traefik_letsencrypt >/dev/null 2>&1 || docker volume create traefik_letsencrypt
docker run --rm -v traefik_letsencrypt:/letsencrypt alpine sh -c 'touch /letsencrypt/acme.json && chmod 600 /letsencrypt/acme.json'

# Subir serviços
echo -e "${YELLOW}🚀 Iniciando containers...${NC}"
(docker compose up -d) >/dev/null 2>&1 & spinner $!

clear
show_animated_logo
echo -e "${GREEN}🎉 Instalação concluída com sucesso!${NC}"
echo -e "${BLUE}🔗 Portainer: ${YELLOW}https://${portainer}${NC}"
echo -e "${BLUE}🔧 Dashboard Traefik: ${YELLOW}https://${traefik}${NC} (user: ${dash_user})"
[ -n "$edge" ] && echo -e "${BLUE}🔌 Edge Tunnel: ${YELLOW}${edge}:8000${NC}" || echo -e "${BLUE}🔌 Edge Tunnel: ${YELLOW}<SEU_IP>:8000${NC}"
