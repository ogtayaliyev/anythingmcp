#!/usr/bin/env bash
# =============================================================================
# AnythingMCP — installation derrière un reverse proxy existant
#
# À lancer depuis /opt/anythingmcp, en tant qu'utilisateur `deploy` :
#   cd /opt/anythingmcp && ./vps/install.sh
#
# Génère un .env déterministe et démarre la stack SANS le profil `proxy`
# (pas de Caddy, donc aucune tentative de bind sur 80/443).
#
# Variables surchargeables :
#   DOMAIN         défaut mcp.vectrum.fr
#   FRONTEND_PORT  défaut 3100
#   BACKEND_PORT   défaut 4100
# =============================================================================
set -euo pipefail

DOMAIN="${DOMAIN:-mcp.vectrum.fr}"
FRONTEND_PORT="${FRONTEND_PORT:-3100}"
BACKEND_PORT="${BACKEND_PORT:-4100}"

info() { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ -f docker-compose.yml ] || die "Lance ce script depuis la racine du dépôt (/opt/anythingmcp)"

# ── Garde-fou : ne jamais écraser des secrets existants ──────────────────────
if [ -f .env ]; then
  die ".env existe déjà — il contient ENCRYPTION_KEY. Supprime-le volontairement si tu veux repartir de zéro (toutes les credentials stockées devront être ressaisies)."
fi

# ── Vérifier que les ports sont libres ───────────────────────────────────────
for p in "$FRONTEND_PORT" "$BACKEND_PORT"; do
  if ss -tln 2>/dev/null | grep -qE "[:.]$p\b"; then
    die "Le port $p est déjà occupé — change FRONTEND_PORT/BACKEND_PORT"
  fi
done
ok "Ports $FRONTEND_PORT et $BACKEND_PORT libres"

# ── Secrets (mêmes générateurs que setup.sh) ─────────────────────────────────
JWT_SECRET=$(openssl rand -hex 32)                       # 64 car. hex
ENCRYPTION_KEY=$(openssl rand -base64 32 | head -c 32)   # exactement 32 car.
NEXTAUTH_SECRET=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
[ "${#ENCRYPTION_KEY}" -eq 32 ] || die "ENCRYPTION_KEY mal générée"
ok "Secrets générés"

URL="https://$DOMAIN"

cat > .env <<ENVEOF
# =============================================================================
# AnythingMCP — généré par vps/install.sh le $(date -Iseconds)
#
# Mode : derrière le Caddy de NexTable. Le profil \`proxy\` est VOLONTAIREMENT
# absent : activer COMPOSE_PROFILES=proxy démarrerait un Caddy qui tenterait de
# prendre les ports 80/443 déjà utilisés par NexTable.
# =============================================================================

# ── General ──────────────────────────────────────────────────────────────────
NODE_ENV=production
COMPOSE_PROJECT_NAME=amcp
PORT=4000

# ── Database ─────────────────────────────────────────────────────────────────
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DATABASE_URL=postgresql://amcp:$POSTGRES_PASSWORD@postgres:5432/anythingmcp

# ── Redis — désactivé (RAM limitée sur cette machine) ────────────────────────
# REDIS_URL=redis://redis:6379

# ── Security ─────────────────────────────────────────────────────────────────
JWT_SECRET=$JWT_SECRET
ENCRYPTION_KEY=$ENCRYPTION_KEY

# ── URLs publiques (tout passe par le même domaine) ──────────────────────────
FRONTEND_URL=$URL
NEXT_PUBLIC_API_URL=$URL
NEXTAUTH_URL=$URL
NEXTAUTH_SECRET=$NEXTAUTH_SECRET
CORS_ORIGIN=$URL
SERVER_URL=$URL

# ── MCP ──────────────────────────────────────────────────────────────────────
MCP_AUTH_MODE=oauth2
MCP_RATE_LIMIT_PER_MINUTE=60
ALLOW_OPEN_REGISTRATION=false

# ── Ports publiés sur l'hôte (loopback uniquement) ───────────────────────────
APP_BIND_IP=127.0.0.1
FRONTEND_PORT=$FRONTEND_PORT
BACKEND_PORT=$BACKEND_PORT

# ── Reverse proxy : géré par NexTable, NE PAS activer ────────────────────────
# COMPOSE_PROFILES=proxy
ENVEOF

chmod 600 .env
ok ".env créé (600)"

info "Récupération de l'image publiée (pas de build local)"
docker compose pull app postgres

info "Démarrage de la stack"
docker compose up -d app postgres

info "Attente du démarrage (migrations au boot, ~30-60 s)"
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$BACKEND_PORT/health" >/dev/null 2>&1; then
    ok "Backend opérationnel"
    break
  fi
  [ "$i" -eq 30 ] && die "Pas de réponse sur /health — voir: docker compose logs app | tail -50"
  sleep 5
done

docker compose ps

cat <<EOF

════════════════════════════════════════════════════════════════════
✓ AnythingMCP tourne sur 127.0.0.1:$FRONTEND_PORT et 127.0.0.1:$BACKEND_PORT

⚠️  SAUVEGARDE CES DEUX VALEURS MAINTENANT, hors du serveur :

    ENCRYPTION_KEY=$ENCRYPTION_KEY
    JWT_SECRET=$JWT_SECRET

    Sans ENCRYPTION_KEY, toutes les credentials des connecteurs sont perdues.

Étape suivante : brancher le Caddy de NexTable (voir vps/nextable/).
════════════════════════════════════════════════════════════════════
EOF
