#!/usr/bin/env bash

# =========================================
#  Install Traefik + Portainer CE (Compose)
#  - NÃO instala Docker (pressupõe já instalado)
#  - Traefik com Let's Encrypt (HTTP-01)
#  - Dashboard Traefik protegido com Basic Auth (htpasswd)
#  - Portainer CE atrás do Traefik (HTTPS)
#  - Edge Tunnel publicado diretamente em 8000/tcp
# =========================================

set -euo pipefail

# Cores
GREEN='\e[32m'; YELLOW='\e[33m'; RED='\e[31m'; BLUE='\e[34m'; NC='\e[0m'

# Spinner
spinner() {
  local pid=$1 delay=0.1 spinstr='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
  printf "      \b\b\b\b\b\b"
}

# Logo
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

# Banner e passos
show_banner() {
  echo -e "${GREEN}=============================================================================="
  echo -e "=                                                                            ="
  echo -e "=                 ${YELLOW}Preencha as informações solicitadas abaixo${GREEN}                 ="
  echo -e "=                                                                            ="
  echo -e "==============================================================================${NC}"
}
show_step() {
  local current=$1 total=6 percent=$((current * 100 / total)) completed=$((percent / 2))
  echo -ne "${GREEN}Passo ${YELLOW}$current/$total ${GREEN}["
  for ((i=0;i<50;i++)); do
    if [ $i -lt $completed ]; then echo -ne "="; else echo -ne " "; fi
  done
  echo -e "] ${percent}%${NC}"
}

# Requisitos
check_requirements() {
  echo -e "${BLUE}Verificando requisitos...${NC}"
  command -v docker >/dev/null 2>&1 || { echo -e "${RED}❌ Docker não encontrado.${NC}"; return 1; }
  command -v docker compose >/dev/null 2>&1 || { echo -e "${RED}❌ 'docker compose' (plugin) não encontrado.${NC}"; return 1; }
  local free_space=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
  if [ "${free_space:-0}" -lt 3 ]; then
    echo -e "${RED}❌ Espaço em disco insuficiente. Precisa de pelo menos 3GB livres.${NC}"; return 1
  fi
  echo -e "${GREEN}✅ Requisitos ok${NC}"
  return 0
}

# Gerar htpasswd (openssl apr1)
make_htpasswd() {
  local user="$1" pass="$2"
  local hash; hash="$(printf "%s" "$pass" | openssl passwd -apr1 -stdin)"
  printf "%s:%s" "$user" "$hash"
}

# ======================
# Fluxo interativo
# ======================
clear
show_animated_logo
show_banner
echo ""

# 1) E-mail LE
show_step 1
read -p "📧 E-mail para Let's Encrypt: " email
echo ""

# 2) Domínio do Traefik (dashboard)
show_step 2
read -p "🌐 Domínio do Traefik (ex: traefik.seudominio.com): " traefik_domain
echo ""

# 3) Usuário/senha do dashboard
show_step 3
read -p "👤 Usuário do dashboard [admin]: " traefik_user
traefik_user=${traefik_user:-admin}
read -s -p "🔑 Senha do dashboard: " traefik_pass; echo ""
if [ -z "$traefik_pass" ]; then
  echo -e "${RED}❌ Senha do dashboard é obrigatória.${NC}"; exit 1
fi
echo ""

# 4) Domínio do Portainer
show_step 4
read -p "🌐 Domínio do Portainer (ex: portainer.seudominio.com): " portainer_domain
echo ""

# 5) Domínio do Edge (opcional, só informativo)
show_step 5
read -p "🌐 Domínio do Edge (opcional, ex: edge.seudominio.com): " edge_domain
echo ""

# 6) Confirmar
show_step 6
echo -e "${BLUE}📋 Resumo:${NC}"
echo -e "📧 E-mail LE:        ${YELLOW}${email}${NC}"
echo -e "🌐 Traefik:          ${YELLOW}${traefik_domain}${NC}"
echo -e "👤 Dashboard user:   ${YELLOW}${traefik_user}${NC}"
echo -e "🌐 Portainer:        ${YELLOW}${portainer_domain}${NC}"
if [ -n "${edge_domain}" ]; then
  echo -e "🌐 Edge (informativo): ${YELLOW}${edge_domain}${NC}"
fi
read -p "As informações estão corretas? (y/n): " confirma
[ "${confirma,,}" = "y" ] || { echo -e "${RED}❌ Cancelado pelo usuário.${NC}"; exit 1; }

clear
check_requirements || exit 1

# ======================
# Preparar diretório
# ======================
WORKDIR="${HOME}/Portainer"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# ======================
# Compose file
# ======================
echo -e "${YELLOW}📝 Gerando docker-compose.yml...${NC}"

htline="$(make_htpasswd "$traefik_user" "$traefik_pass")"

cat > docker-compose.yml <<EOL
version: "3.8"

services:
  traefik:
    image: "traefik:2.11"
    container_name: traefik
    restart: always
    command:
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --api.dashboard=true
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --log.level=ERROR
      # Let's Encrypt (HTTP-01)
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
      # redirect HTTP -> HTTPS (catchall)
      - "traefik.http.routers.http-catchall.rule=HostRegexp(\`{host:.+}\`)"
      - "traefik.http.routers.http-catchall.entrypoints=web"
      - "traefik.http.routers.http-catchall.middlewares=redirect-to-https"
      - "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
      # Dashboard em HTTPS com Basic Auth
      - "traefik.http.routers.traefik.rule=Host(\`${traefik_domain}\`)"
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
      # UI do Portainer via HTTPS (Traefik)
      - "traefik.http.routers.portainer.rule=Host(\`${portainer_domain}\`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=le"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"
    # Edge exposto diretamente (TCP 8000)
    ports:
      - "8000:8000"

volumes:
  traefik_letsencrypt:
  portainer_data:
EOL

# ======================
# Permissões do ACME
# ======================
echo -e "${YELLOW}🔐 Preparando armazenamento de certificados...${NC}"
TMP_ACME_DIR="$(mktemp -d)"
touch "${TMP_ACME_DIR}/acme.json"
chmod 600 "${TMP_ACME_DIR}/acme.json"

# Montar volume traefik_letsencrypt se vazio e copiar acme.json
docker volume inspect traefik_letsencrypt >/dev/null 2>&1 || docker volume create traefik_letsencrypt >/dev/null
# copiar acme.json para o volume (se não existir)
docker run --rm -v traefik_letsencrypt:/letsencrypt -v "${TMP_ACME_DIR}:/seed" alpine:3.19 \
  sh -c 'test -f /letsencrypt/acme.json || cp /seed/acme.json /letsencrypt/acme.json && chmod 600 /letsencrypt/acme.json' >/dev/null

rm -rf "${TMP_ACME_DIR}"

# ======================
# Subir containers
# ======================
echo -e "${YELLOW}🚀 Subindo Traefik + Portainer CE...${NC}"
( docker compose up -d ) >/dev/null 2>&1 & spinner $!

clear
show_animated_logo
echo -e "${GREEN}🎉 Instalação concluída com sucesso!${NC}"
echo -e "${BLUE}📝 Informações de Acesso:${NC}"
echo -e "${GREEN}================================${NC}"
echo -e "🔗 Portainer CE: ${YELLOW}https://${portainer_domain}${NC}"
echo -e "🔧 Dashboard Traefik: ${YELLOW}https://${traefik_domain}${NC}  ${NC}(user: ${traefik_user})"
if [ -n "${edge_domain}" ]; then
  echo -e "🔌 Edge Tunnel (TCP): ${YELLOW}${edge_domain}:8000${NC}"
else
  echo -e "🔌 Edge Tunnel (TCP): ${YELLOW}<SEU_IP>:8000${NC}"
fi
echo -e "${GREEN}================================${NC}"
echo -e "${BLUE}💡 Dica: os certificados podem levar alguns minutos para serem emitidos (Let's Encrypt).${NC}"
