# Déploiement AnythingMCP sur VPS

Runbook pour `ogtayaliyev/anythingmcp`. Edition Community (AGPL-3.0) : gratuite,
jusqu'à 3 utilisateurs actifs, tous les connecteurs inclus.

---

## Architecture — cohabitation avec un service existant

Ce VPS héberge déjà **NexTable** en production, qui occupe les ports 80 et 443.
Le profil `proxy` d'AnythingMCP (Caddy, `80:80` + `443:443`) est donc **désactivé** :
on réutilise le reverse proxy déjà en place.

```
Internet ──HTTPS──► reverse proxy existant (80/443)
                      ├─ nextable.tld      ──► NexTable        (inchangé)
                      └─ mcp.tondomaine.tld ──► 127.0.0.1:3100  (dashboard)
                                            └─► 127.0.0.1:4100  (API + /mcp)

Stack AnythingMCP (réseau Docker interne, rien de publié sur l'extérieur) :
  app · postgres · redis
```

Postgres et Redis ne publient aucun port sur l'hôte : aucun risque de collision
avec les bases de NexTable. Le projet Compose s'appelle `amcp`, les conteneurs
sont préfixés `amcp-` : pas de collision de noms non plus.

| Variable `.env` | Valeur | Rôle |
|---|---|---|
| `APP_BIND_IP` | `127.0.0.1` | rien n'est exposé publiquement |
| `FRONTEND_PORT` | `3100` | dashboard, derrière le proxy |
| `BACKEND_PORT` | `4100` | API + `/mcp`, derrière le proxy |
| `COMPOSE_PROFILES` | *(vide)* | **ne pas** mettre `proxy` |
| `SERVER_URL` | `https://mcp.tondomaine.tld` | redirections OAuth2 |
| `CORS_ORIGIN` | `https://mcp.tondomaine.tld` | appels du dashboard |

> ⚠️ `SERVER_URL` doit être l'URL **publique** en HTTPS, pas `localhost` :
> sinon le flux OAuth2 des clients MCP redirige dans le vide.

---

## 1. Prérequis

| Élément | Minimum |
|---|---|
| OS | Ubuntu 22.04 / 24.04 ou Debian 12 |
| Docker | 24 ou plus |
| Architecture | amd64 (l'image publiée est amd64 uniquement) |
| RAM | 2 Go (4 Go confortable) |
| Disque | 20 Go |
| Réseau | ports 80 et 443 ouverts |
| DNS | un enregistrement A `mcp.tondomaine.com` → IP du VPS |

Le DNS doit pointer **avant** de lancer `setup.sh`, sinon Let's Encrypt échoue.

---

## 2. Préflight (lecture seule)

À lancer en premier sur une machine qui a déjà des services en production :

```bash
curl -fsSL https://raw.githubusercontent.com/ogtayaliyev/anythingmcp/main/vps/preflight.sh | bash
```

Ne modifie rien. Inventorie Docker, les conteneurs en cours, les ports occupés,
le reverse proxy en place et les ports candidats libres.

## 3. Bootstrap du VPS (une fois)

```bash
curl -fsSL https://raw.githubusercontent.com/ogtayaliyev/anythingmcp/main/vps/bootstrap.sh -o bootstrap.sh
sudo bash bootstrap.sh
```

Installe Docker (s'il manque), crée l'utilisateur `deploy`, génère les deux clés
SSH, puis affiche les clés à coller dans GitHub.
**Ne touche pas au firewall** ni aux services existants.

---

## 3. Configurer GitHub

### Deploy key (VPS → GitHub, lecture seule)

`Settings → Deploy keys → Add deploy key` → coller la clé **publique** affichée
par le bootstrap. Laisser « Allow write access » décoché.

### Secrets Actions (GitHub → VPS)

`Settings → Secrets and variables → Actions → New repository secret`

| Secret | Valeur | Requis |
|---|---|---|
| `VPS_HOST` | IP publique du VPS | oui |
| `VPS_USER` | `deploy` | oui |
| `VPS_SSH_KEY` | clé **privée** `github_actions` affichée par le bootstrap | oui |
| `VPS_PORT` | port SSH si ≠ 22 | non |
| `VPS_APP_DIR` | `/opt/anythingmcp` | non |

> La clé privée se colle en entier, lignes `-----BEGIN…` et `-----END…` comprises.

---

## 4. Première installation

```bash
sudo -iu deploy
git clone git@github.com:ogtayaliyev/anythingmcp.git /opt/anythingmcp
cd /opt/anythingmcp
./setup.sh
```

Réponses attendues :

- **Reverse proxy / HTTPS** → oui
- **Domaine** → `mcp.tondomaine.com`
- **Email Let's Encrypt** → ton email

`setup.sh` génère `.env` (secrets inclus), écrit le `Caddyfile`, crée la base et
démarre la stack. Les deux fichiers sont gitignorés : ils survivent aux déploiements.

### ⚠️ Sauvegarder les secrets immédiatement

```bash
cat /opt/anythingmcp/.env
```

Copie `ENCRYPTION_KEY` et `JWT_SECRET` dans ton gestionnaire de mots de passe.
**Si `ENCRYPTION_KEY` est perdue, toutes les credentials des connecteurs sont à ressaisir.**

### Créer le compte admin

Ouvre `https://mcp.tondomaine.com` — le premier compte créé devient admin.
`ALLOW_OPEN_REGISTRATION=false` par défaut : personne d'autre ne peut s'inscrire.

---

## 5. Déploiements suivants

Automatiques : chaque push sur `main` déclenche `.github/workflows/deploy-vps.yml`
(fetch, reset, `docker compose pull`, `up -d`, health check sur `/health`).

Manuel : `Actions → Deploy VPS → Run workflow`.
Cocher *rebuild* pour reconstruire les images au lieu de les tirer.

---

## 6. Récupérer les mises à jour upstream

```bash
git remote add upstream https://github.com/HelpCode-ai/anythingmcp.git   # une fois
git fetch upstream
git merge upstream/main
git push origin main        # déclenche le déploiement
```

---

## 7. Brancher Claude

Dans le dashboard : créer un connecteur, importer la spec (OpenAPI / WSDL /
GraphQL / SQL), publier un serveur MCP, générer un token.

**Claude Code**

```bash
claude mcp add --transport http anythingmcp https://mcp.tondomaine.com/mcp \
  --header "Authorization: Bearer <TON_TOKEN>"
```

**Claude.ai / Claude Desktop** — Paramètres → Connecteurs → connecteur
personnalisé → URL `https://mcp.tondomaine.com/mcp`.
`MCP_AUTH_MODE=oauth2` par défaut : le flux OAuth se fait dans le navigateur.

---

## 8. Exploitation

```bash
cd /opt/anythingmcp

docker compose ps                  # état
docker compose logs -f app         # logs backend
docker compose restart app         # redémarrage

# Sauvegarde Postgres
docker compose exec -T postgres pg_dump -U amcp anythingmcp | gzip > ~/backup-$(date +%F).sql.gz
```

Cron de sauvegarde quotidienne (`crontab -e` en tant que `deploy`) :

```cron
0 3 * * * cd /opt/anythingmcp && docker compose exec -T postgres pg_dump -U amcp anythingmcp | gzip > ~/backups/amcp-$(date +\%F).sql.gz && find ~/backups -name 'amcp-*.sql.gz' -mtime +14 -delete
```

---

## 9. Dépannage

| Symptôme | Piste |
|---|---|
| Certificat TLS absent | DNS pas encore propagé, ou port 80 fermé — `ufw status` |
| 502 via Caddy | `docker compose logs app` ; l'app met ~30 s à démarrer (migrations) |
| Workflow « Permission denied (publickey) » | `VPS_SSH_KEY` tronquée, ou clé publique absente de `~deploy/.ssh/authorized_keys` |
| `git reset` échoue sur le VPS | deploy key manquante : `sudo -iu deploy ssh -T git@github.com` |
| Health check KO | `docker compose logs app \| tail -50` — souvent Postgres pas prêt |

---

## Licence

AGPL-3.0. Gratuit en self-host, usage commercial compris, jusqu'à 3 utilisateurs
actifs. Payant : au-delà de 3 utilisateurs, SSO/SCIM, File Search après l'essai
de 30 jours, et le dossier `ee/` (non nécessaire ici).
