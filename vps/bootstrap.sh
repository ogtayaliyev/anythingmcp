#!/usr/bin/env bash
# =============================================================================
# AnythingMCP — bootstrap VPS (Ubuntu/Debian)
#
# À lancer UNE SEULE FOIS sur le VPS, en root ou avec sudo :
#
#   curl -fsSL https://raw.githubusercontent.com/<USER>/anythingmcp/main/vps/bootstrap.sh -o bootstrap.sh
#   sudo bash bootstrap.sh
#
# Le script :
#   1. installe Docker + Docker Compose
#   2. crée l'utilisateur `deploy` et sa clé SSH de déploiement
#   3. configure le firewall (22, 80, 443)
#   4. affiche les clés à copier dans GitHub
# Ensuite : ajouter la Deploy key, cloner le repo et lancer ./setup.sh
# =============================================================================
set -euo pipefail

REPO_SSH="${REPO_SSH:-git@github.com:ogtayaliyev/anythingmcp.git}"
APP_DIR="${APP_DIR:-/opt/anythingmcp}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Lance ce script en root (sudo bash bootstrap.sh)"

# ── 1. Paquets de base ───────────────────────────────────────────────────────
info "Installation des paquets de base"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git openssl ufw >/dev/null
ok "Paquets installés"

# ── 2. Docker ────────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  ok "Docker déjà présent : $(docker --version)"
else
  info "Installation de Docker"
  curl -fsSL https://get.docker.com | sh >/dev/null
  ok "Docker installé : $(docker --version)"
fi

docker compose version >/dev/null 2>&1 || die "Docker Compose v2 introuvable"
DOCKER_MAJOR=$(docker version --format '{{.Server.Version}}' | cut -d. -f1)
[ "${DOCKER_MAJOR:-0}" -ge 24 ] || echo "⚠️  Docker $DOCKER_MAJOR détecté — AnythingMCP demande 24 ou plus"

systemctl enable --now docker >/dev/null 2>&1 || true

# ── 3. Utilisateur de déploiement ────────────────────────────────────────────
if id "$DEPLOY_USER" >/dev/null 2>&1; then
  ok "Utilisateur $DEPLOY_USER déjà présent"
else
  info "Création de l'utilisateur $DEPLOY_USER"
  adduser --disabled-password --gecos "" "$DEPLOY_USER" >/dev/null
  ok "Utilisateur créé"
fi
usermod -aG docker "$DEPLOY_USER"

HOME_DIR=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$HOME_DIR/.ssh"

# ── 4. Clé SSH : GitHub Actions → VPS ────────────────────────────────────────
CI_KEY="$HOME_DIR/.ssh/github_actions"
if [ ! -f "$CI_KEY" ]; then
  info "Génération de la clé GitHub Actions → VPS"
  sudo -u "$DEPLOY_USER" ssh-keygen -t ed25519 -N "" -C "github-actions@anythingmcp" -f "$CI_KEY" >/dev/null
  cat "$CI_KEY.pub" >> "$HOME_DIR/.ssh/authorized_keys"
  chmod 600 "$HOME_DIR/.ssh/authorized_keys"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$HOME_DIR/.ssh/authorized_keys"
  ok "Clé CI générée"
fi

# ── 5. Clé SSH : VPS → GitHub (deploy key) ───────────────────────────────────
REPO_KEY="$HOME_DIR/.ssh/id_ed25519"
if [ ! -f "$REPO_KEY" ]; then
  info "Génération de la deploy key VPS → GitHub"
  sudo -u "$DEPLOY_USER" ssh-keygen -t ed25519 -N "" -C "vps@anythingmcp" -f "$REPO_KEY" >/dev/null
  ok "Deploy key générée"
fi
ssh-keyscan github.com >> "$HOME_DIR/.ssh/known_hosts" 2>/dev/null
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$HOME_DIR/.ssh"

# ── 6. Firewall (lecture seule) ──────────────────────────────────────────────
# On ne touche PAS au firewall : la machine héberge déjà des services en
# production. AnythingMCP n'écoute que sur 127.0.0.1 et passe par le reverse
# proxy existant, donc aucune ouverture de port n'est nécessaire.
info "Firewall (inspection seule, aucune modification)"
ufw status 2>/dev/null | head -8 | sed 's/^/    /' || echo "    ufw non installé"

# ── 7. Dossier applicatif ────────────────────────────────────────────────────
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_DIR"
ok "Dossier $APP_DIR prêt"

# ── Résumé ───────────────────────────────────────────────────────────────────
echo
bold "═══════════════ ÉTAPE SUIVANTE : 2 clés à copier dans GitHub ═══════════════"
echo
bold "1) DEPLOY KEY — Settings → Deploy keys → Add deploy key (lecture seule) :"
echo
cat "$REPO_KEY.pub"
echo
bold "2) SECRET VPS_SSH_KEY — Settings → Secrets and variables → Actions :"
echo "   (copie tout, y compris les lignes BEGIN/END)"
echo
cat "$CI_KEY"
echo
bold "3) Les autres secrets Actions :"
echo "   VPS_HOST     = $(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<ton IP>')"
echo "   VPS_USER     = $DEPLOY_USER"
echo "   VPS_APP_DIR  = $APP_DIR"
echo
bold "4) Puis, une fois la deploy key ajoutée :"
cat <<EOF

   sudo -iu $DEPLOY_USER
   git clone $REPO_SSH $APP_DIR
   cd $APP_DIR
   ./setup.sh

   ⚠️  COHABITATION : si un reverse proxy tourne déjà sur cette machine,
   réponds NON au reverse proxy Caddy (il voudrait les ports 80 et 443),
   puis fixe des ports libres dans .env :

       APP_BIND_IP=127.0.0.1
       FRONTEND_PORT=3100
       BACKEND_PORT=4100
       SERVER_URL=https://<ton-domaine>
       CORS_ORIGIN=https://<ton-domaine>

   et ajoute un vhost au proxy existant vers ces deux ports.

EOF
bold "═══════════════════════════════════════════════════════════════════════════"
