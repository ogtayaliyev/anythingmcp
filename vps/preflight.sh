#!/usr/bin/env bash
# =============================================================================
# AnythingMCP — préflight VPS (lecture seule, ne modifie RIEN)
#
#   curl -fsSL https://raw.githubusercontent.com/ogtayaliyev/anythingmcp/main/vps/preflight.sh | bash
#
# Inventorie la machine pour planifier une installation SANS conflit avec les
# services déjà en production.
# =============================================================================
set -uo pipefail

h() { printf '\n\033[1m── %s ─────────────────────────────\033[0m\n' "$*"; }

h "SYSTÈME"
. /etc/os-release 2>/dev/null && echo "OS       : $PRETTY_NAME"
echo "Kernel   : $(uname -r)  |  Arch : $(uname -m)"
echo "CPU      : $(nproc) vCPU"
free -h | awk '/Mem:/ {print "RAM      : "$2" total, "$7" dispo"}'
df -h / | awk 'NR==2 {print "Disque / : "$2" total, "$4" dispo ("$5" utilisé)"}'

h "DOCKER"
docker --version 2>/dev/null || echo "docker ABSENT"
docker compose version 2>/dev/null || echo "docker compose v2 ABSENT"

h "CONTENEURS EN COURS"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || echo "(docker inaccessible sans sudo ?)"

h "PROJETS COMPOSE EXISTANTS"
docker ps --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sort -u | grep -v '^$' || echo "(aucun)"

h "PORTS TCP EN ÉCOUTE"
(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | awk 'NR==1 || /LISTEN/'

h "PORTS CANDIDATS POUR ANYTHINGMCP"
for p in 3100 3200 4100 4200 5100; do
  if (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -qE "[:.]$p\b"; then
    echo "  $p : OCCUPÉ"
  else
    echo "  $p : libre"
  fi
done

h "REVERSE PROXY DÉTECTÉ"
found=0
for svc in nginx apache2 caddy traefik haproxy; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "  systemd : $svc actif"; found=1
  fi
done
docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
  | grep -Ei 'nginx|caddy|traefik|haproxy|npm|proxy' \
  | sed 's/^/  docker  : /' && found=1
[ "$found" -eq 0 ] && echo "  (aucun proxy identifié — à confirmer)"

h "VHOSTS NGINX (si présent)"
ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^/  /' || echo "  (pas de /etc/nginx/sites-enabled)"
ls -1 /etc/nginx/conf.d/*.conf 2>/dev/null | sed 's/^/  /'

h "FIREWALL"
ufw status 2>/dev/null | head -12 || echo "  ufw non installé"

h "RÉSOLUTION DNS"
echo "IP publique : $(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '?')"

printf '\n\033[1m✓ Préflight terminé — copie toute cette sortie.\033[0m\n'
