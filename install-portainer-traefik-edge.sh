#!/usr/bin/env bash
set -euo pipefail

BLUE="$(printf '\033[34m')"; GREEN="$(printf '\033[32m')"; YELLOW="$(printf '\033[33m')"; RED="$(printf '\033[31m')"; RESET="$(printf '\033[0m')"
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

ensure_swarm_manager(){
  command -v docker >/dev/null 2>&1 || die "Docker não encontrado."
  local state role
  state="$(docker info --format '{{.Swarm.LocalNodeState}}' || true)"
  role="$(docker info --format '{{.Swarm.ControlAvailable}}' || true)"
  [ "$state" = "active" ] || die "Swarm não está ativo. Inicie com: docker swarm init --advertise-addr <SEU_IP>"
  echo "$role" | grep -qi 'true' || die "Este nó não é manager. Rode no manager."
}

gather_inputs(){
  LE_EMAIL="${LE_EMAIL:-}"
  PORTAINER_DOMAIN="${PORTAINER_DOMAIN:-}"
  ENABLE_TRAEFIK_DASH="${ENABLE_TRAEFIK_DASH:-no}"
  TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN:-}"
  ACME_STAGING="${ACME_STAGING:-no}"

  if [ -z "$LE_EMAIL" ]; then
    read -r -p "E-mail para Let's Encrypt (LE_EMAIL): " LE_EMAIL
  fi
  [ -z "$LE_EMAIL" ] && die "LE_EMAIL é obrigatório."

  if [ -z "$PORTAINER_DOMAIN" ]; then
    read -r -p "Domínio para o Portainer (PORTAINER_DOMAIN), ex: portainer.exemplo.com: " PORTAINER_DOMAIN
  fi
  [ -z "$PORTAINER_DOMAIN" ] && die "PORTAINER_DOMAIN é obrigatório."

  if [ -z "$ENABLE_TRAEFIK_DASH" ]; then
    ENABLE_TRAEFIK_DASH="no"
  fi
  if [ "${ENABLE_TRAEFIK_DASH}" = "yes" ] && [ -z "$TRAEFIK_DOMAIN" ]; then
    read -r -p "Domínio para o Traefik Dashboard (TRAEFIK_DOMAIN), ex: traefik.exemplo.com: " TRAEFIK_DOMAIN
    [ -z "$TRAEFIK_DOMAIN" ] && die "TRAEFIK_DOMAIN é obrigatório quando ENABLE_TRAEFIK_DASH=yes."
  fi

  if [ -z "$ACME_STAGING" ]; then
    ACME_STAGING="no"
  fi

  export LE_EMAIL PORTAINER_DOMAIN ENABLE_TRAEFIK_DASH TRAEFIK_DOMAIN ACME_STAGING
}

prepare_networks_volumes(){
  log "Criando rede overlay 'proxy' (se não existir)..."
  docker network inspect proxy >/dev/null 2>&1 || docker network create --driver=overlay --attachable proxy

  log "Criando volume 'traefik_letsencrypt' (se não existir)..."
  docker volume inspect traefik_letsencrypt >/dev/null 2>&1 || docker volume create traefik_letsencrypt

  log "Criando volume 'portainer_data' (se não existir)..."
  docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data
}

write_traefik_stack(){
  local acmeCas="https://acme-v02.api.letsencrypt.org/directory"
  [ "$ACME_STAGING" = "yes" ] && acmeCas="https://acme-staging-v02.api.letsencrypt.org/directory"

  cat > traefik-stack.yml <<EOF
version: "3.8"

services:
  traefik:
    image: traefik:2.11
    command:
      - --providers.docker.swarmMode=true
      - --providers.docker.endpoint=unix:///var/run/docker.sock
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.email=${LE_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.caServer=${acmeCas}
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --api.dashboard=$( [ "${ENABLE_TRAEFIK_DASH}" = "yes" ] && echo "true" || echo "false" )
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: host
      - target: 443
        published: 443
        protocol: tcp
        mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_letsencrypt:/letsencrypt
    networks:
      - proxy
    deploy:
      placement:
        constraints:
          - node.role == manager
      labels:
        - traefik.enable=true
$( if [ "${ENABLE_TRAEFIK_DASH}" = "yes" ]; then cat <<'DASH'
        - traefik.http.routers.traefik.rule=Host(`${TRAEFIK_DOMAIN}`)
        - traefik.http.routers.traefik.entrypoints=websecure
        - traefik.http.routers.traefik.tls.certresolver=le
        - traefik.http.routers.traefik.service=api@internal
DASH
fi)

volumes:
  traefik_letsencrypt:

networks:
  proxy:
    external: true
EOF
}

write_portainer_stack(){
  cat > portainer-stack.yml <<EOF
version: "3.8"

services:
  portainer:
    image: portainer/portainer-ce:latest
    command:
      - --http-enabled                 # habilita porta 9000 (HTTP) para o Traefik fazer proxy TLS
      - --tlsskipverify                # evita erro se proxy fizer TLS interno; ajuste conforme política
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
        - traefik.enable=true
        # Roteamento HTTP(S) para UI do Portainer
        - traefik.http.routers.portainer.rule=Host(`${PORTAINER_DOMAIN}`)
        - traefik.http.routers.portainer.entrypoints=websecure
        - traefik.http.routers.portainer.tls.certresolver=le
        - traefik.http.services.portainer.loadbalancer.server.port=9000
    # Publica 8000 (Edge Tunnel) direto, sem Traefik (recomendado pela simplicidade)
    ports:
      - target: 8000
        published: 8000
        protocol: tcp
        mode: host

volumes:
  portainer_data:

networks:
  proxy:
    external: true
EOF
}

deploy_stacks(){
  log "Fazendo deploy do Traefik..."
  docker stack deploy -c traefik-stack.yml traefik

  # Espera o Traefik estar saudável o suficiente (melhor tentativa simples)
  log "Aguardando 10s para o Traefik iniciar..."
  sleep 10

  log "Fazendo deploy do Portainer CE..."
  docker stack deploy -c portainer-stack.yml portainer

  ok "Stacks enviados. Aguarde os containers ficarem 'Running'."
}

post_info(){
  echo
  ok "Concluído!"
  cat <<INFO
Acesse a UI do Portainer (via Traefik/HTTPS):
  https://${PORTAINER_DOMAIN}

Edge Tunnel (para agentes Edge) exposto em:
  tcp://${PORTAINER_DOMAIN}:8000   (se seu DNS A aponta para este servidor)
  ou  tcp://<IP_DO_SERVIDOR>:8000

Dicas:
- Se usou ACME_STAGING=yes, troque para 'no' depois que tudo estiver OK e redeploy do Traefik para certificados válidos.
- Para ver serviços:    docker stack services traefik && docker stack services portainer
- Logs Traefik:         docker service logs -f traefik_traefik
- Logs Portainer:       docker service logs -f portainer_portainer

Para remover:
  docker stack rm portainer
  docker stack rm traefik
  docker network rm proxy    # somente se não houver mais serviços usando
  docker volume rm traefik_letsencrypt portainer_data  # cuidado, remove dados
INFO
}

main(){
  need_root "$@"
  ensure_swarm_manager
  gather_inputs
  prepare_networks_volumes
  write_traefik_stack
  write_portainer_stack
  deploy_stacks
  post_info
}

main "$@"
