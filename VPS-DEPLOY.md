# Déploiement AnythingMCP sur VPS

Runbook pour `ogtayaliyev/anythingmcp`. Edition Community (AGPL-3.0) : gratuite,
jusqu'à 3 utilisateurs actifs, tous les connecteurs inclus.

---

## Architecture

```
Internet ──HTTPS──► Caddy (443) ──► app:4000  (API + /mcp)
                     │              └► frontend:3000 (dashboard)
                     │
                     ├── postgres  (credentials chiffrées AES-256-GCM)
                     └── redis     (cache + rate limit)
```

Un seul domaine sert tout : `https://mcp.tondomaine.com` pour le dashboard,
`https://mcp.tondomaine.com/mcp` pour l'endpoint MCP.
Caddy obtient le certificat Let's Encrypt automatiquement.

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

## 2. Bootstrap du VPS (une fois)

```bash
ssh root@<IP_DU_VPS>
curl -fsSL https://raw.githubusercontent.com/ogtayaliyev/anythingmcp/main/vps/bootstrap.sh -o bootstrap.sh
sudo bash bootstrap.sh
```

Le script installe Docker, crée l'utilisateur `deploy`, génère les deux clés SSH,
configure le firewall, puis affiche les clés à coller dans GitHub.

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
