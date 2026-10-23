# LinkedIn Agent

A self-hosted LinkedIn data layer for our research agents (n8n + Claude).

| Job | How |
|---|---|
| **Profile scrape**: take a LinkedIn URL and store the full profile (every job and degree) in Postgres | n8n webhook `POST /webhook/linkedin-profile` → [stickerdaniel/linkedin-mcp-server](https://github.com/stickerdaniel/linkedin-mcp-server) → Claude structures the text → Postgres |
| **CSR contacts**: find CSR, Sustainability, Foundation and HR people at a company in Sales Navigator | n8n webhook `POST /webhook/csr-leads` → [globodai Sales Navigator MCP](https://github.com/globodai-group/mcp-linkedin-sales-navigator) → Claude ranks the leads → Postgres |
| **Ad-hoc lookups from Claude** | Claude connects to the same MCP servers through Nginx (bearer token) |

```
Claude ── https://MCP_DOMAIN/<service>/mcp ── Nginx (TLS + bearer) ──┐
                                                                      ├── li-profile-<acct>  (one container per LinkedIn account, own proxy)
n8n ───── http://<service>:<port>/mcp ── podman network "n8n-production_n8n-net" ┤
                                                                      └── li-salesnav        (Sales Navigator seat, own proxy)
n8n ───── existing n8n Postgres on "n8n-production_n8n-net" (database PG_DB, schema "linkedin")
```

Each LinkedIn account runs in its own container, with its own saved session and its own sticky proxy. Add accounts to add capacity.

> **Risk.** Automated access breaks LinkedIn's User Agreement. Accounts can be restricted, including a paid Sales Navigator seat. Use dedicated accounts, keep the daily caps low, and treat the stored profiles as personal data (DPDP Act): keep only what you need, and delete on request.

---

## 1. Prerequisites (AWS instance)

- Fedora 44 or newer EC2 instance (the one that already runs n8n), at least 4 GB RAM. Each account's browser uses about 500 MB to 1 GB. Leave SELinux in enforcing mode; the steps below account for it.
- Podman 5 or newer, with `podman-compose` so that `podman compose` works (`podman compose version`). The scripts call `podman` and `podman compose`.
  - Run this stack as the same user as n8n's containers (rootless as that user, or rootful with `sudo`). Podman keeps containers and networks per user, so this stack can only join n8n's `n8n-production_n8n-net` network from the same side. On our server n8n runs rootful, so run every `podman` command and every script except `scripts/mcp-call.sh` with `sudo`. `git`, editing `.env` and `mcp-call.sh` need no `sudo`.
  - Containers come back after a reboot only if `podman-restart.service` is enabled for that user.
- Nginx on the host, with certbot:
  ```bash
  sudo dnf -y install nginx certbot python3-certbot-nginx
  sudo systemctl enable --now nginx
  ```
  Fedora does not start Nginx after install, and SELinux stops it from proxying to local ports. `install-nginx.sh` turns on the `httpd_can_network_connect` SELinux boolean for you.
- `git`, `openssl`, `envsubst` (`sudo dnf -y install git openssl /usr/bin/envsubst`).
- If `firewalld` is running (`sudo firewall-cmd --state`), open HTTP and HTTPS: `sudo firewall-cmd --permanent --add-service={http,https} && sudo firewall-cmd --reload`. Fedora Cloud images on EC2 usually do not run it.
- DNS **A records** pointing at the instance's public IP:
  - `MCP_DOMAIN` (for example `li-mcp.yourorg.com`): MCP endpoints for Claude
  - `LOGIN_DOMAIN` (for example `li-login.yourorg.com`): the page where account owners log in
  - `SALESNAV_LOGIN_DOMAIN` (for example `sn-login.yourorg.com`): the Sales Navigator browser page. Optional until you set up Sales Navigator (step 5).
- Security group: allow inbound 80 and 443. **Do not** open 6080, 6081, 8100 or 82xx. They bind to `127.0.0.1` only.
- One **sticky residential/ISP proxy per LinkedIn account** (for example Bright Data, Oxylabs, IPRoyal or Smartproxy). Ask for a "sticky session" that keeps one IP for days, never per-request rotation.
  - Profile accounts accept `user:password` proxies.
  - The Sales Navigator browser needs an **IP-whitelisted** proxy endpoint: whitelist the EC2 public IP at the provider. Only needed for step 5.
  - Testing without a proxy works, but the login then comes from an AWS datacenter IP, which LinkedIn trusts less.

## 2. Install

```bash
sudo mkdir -p /opt/linkedin-agent && sudo chown $USER: /opt/linkedin-agent
git clone git@github.com:khamsakamal48/linkedin-agent.git /opt/linkedin-agent
cd /opt/linkedin-agent
cp .env.example .env
nano .env    # set PG_PASSWORD, MCP_BEARER_TOKEN (openssl rand -hex 32), the three domains
```

The stack has no Postgres of its own. It uses the Postgres that n8n already runs, in a separate database (`PG_DB`, owned by `PG_USER`, both from `.env`), and joins n8n's `n8n-production_n8n-net` network. Find the Postgres container and its admin user (the `POSTGRES_USER` it was started with), then create the database and load the schema:

```bash
sudo podman network ls | grep n8n-production_n8n-net     # must exist; the stack refuses to start without it
sudo podman ps --filter network=n8n-production_n8n-net   # note the Postgres container name: n8n-postgres
PG=n8n-postgres; PG_ADMIN=CHANGE_ME     # <- set to DB_USER from n8n's own .env
set -a; . ./.env; set +a
sudo podman exec -i "$PG" psql -v ON_ERROR_STOP=1 -U "$PG_ADMIN" -d postgres \
  -v user="$PG_USER" -v pw="$PG_PASSWORD" -v db="$PG_DB" <<'SQL'
create role :"user" login password :'pw';
create database :"db" owner :"user";
SQL
sudo podman exec -i "$PG" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" < db/schema.sql
sudo podman exec "$PG" psql -U "$PG_USER" -d "$PG_DB" -c '\dt linkedin.*'   # should list 5 tables
```

If `PG_USER` already exists in that Postgres, drop the `create role` line. `db/schema.sql` is idempotent, so re-running the last two commands is safe. The tables always land in the `linkedin` schema, whatever `PG_DB` is called.

> Clone into `/opt`, not your home directory. On Fedora, home directories are private (mode `700`, SELinux type `user_home_t`), so Nginx could not read the routes and password files that the scripts write under `nginx/`.

> Run compose commands through `scripts/compose.sh` (for example `sudo scripts/compose.sh ps`). It passes both compose files and `COMPOSE_PROFILES` from `.env` to `podman compose`.

> The scripts are executable in git. If you copied the files some other way, run `chmod +x scripts/*.sh`.

## 3. Nginx + TLS (before the first account)

Do this before adding any account. The owner's login page (`https://LOGIN_DOMAIN/`) and Claude's MCP endpoints only exist once Nginx serves them, and without TLS the page password and the bearer token would cross the internet in plain text.

```bash
sudo scripts/install-nginx.sh
sudo certbot --nginx -d li-mcp.yourorg.com -d li-login.yourorg.com -d sn-login.yourorg.com
```

Not using Sales Navigator yet? Leave `-d sn-login.yourorg.com` out of the certbot command (it fails if that DNS record does not exist). `SALESNAV_LOGIN_DOMAIN` must still be set in `.env`, because `install-nginx.sh` renders its server block. Add the domain later with `sudo certbot --nginx -d sn-login.yourorg.com` when you reach step 5.

`install-nginx.sh` renders `nginx/linkedin-agent.conf.tmpl` from `.env` and adds one `/<service>/mcp` route per account. It links the result into `/etc/nginx/conf.d/` and reloads Nginx. **Re-run it after every new account.** Certbot edits the rendered file in place to add TLS, so after re-running `install-nginx.sh`, run `sudo certbot --nginx` again (it reuses the existing certificates).

Routes:

| URL | Goes to | Protected by |
|---|---|---|
| `https://MCP_DOMAIN/li-profile-<acct>/mcp` | profile server of that account | `Authorization: Bearer $MCP_BEARER_TOKEN` |
| `https://MCP_DOMAIN/li-salesnav/mcp` | Sales Navigator server | same bearer token |
| `https://LOGIN_DOMAIN/` | login browser (only while `add-account.sh` is waiting) | one-time password printed by the script |
| `https://SALESNAV_LOGIN_DOMAIN/` | Sales Navigator browser | password from `sudo scripts/salesnav-password.sh` |

Check before going on:
- `curl -s -o /dev/null -w '%{http_code}\n' https://li-mcp.yourorg.com/li-salesnav/mcp` prints `401` (the token check runs before any account exists).
- `https://li-login.yourorg.com/` opens over HTTPS, asks for a password and rejects every attempt. That is correct: no login is running.

## 4. Add a LinkedIn account (profile scraping)

The full walkthrough, with what the owner sees, is in **[docs/ACCOUNT-SETUP.md](docs/ACCOUNT-SETUP.md)**. In short:

```bash
sudo scripts/add-account.sh acct-a          # asks for the proxy, prints a link + password
sudo scripts/install-nginx.sh && sudo certbot --nginx   # after the login: publishes this account's route
```

1. Send the printed link and password to the account owner (yourself while testing). The one-page guide for owners is [docs/OWNER-GUIDE.md](docs/OWNER-GUIDE.md).
2. The owner opens the link, signs in to LinkedIn and approves 2FA. When the login finishes, the script starts `li-profile-acct-a`.
3. Check it, locally and through Nginx:
   ```bash
   scripts/mcp-call.sh http://127.0.0.1:8201/mcp get_my_profile '{}'
   MCP_TOKEN=<token> scripts/mcp-call.sh https://li-mcp.yourorg.com/li-profile-acct-a/mcp tools/list
   ```

**Nobody on our side ever sees the LinkedIn password.** The owner types it into a browser that runs on this server. Only the session cookies are stored, in `data/<account>/`.

## 5. Sales Navigator account

Needs a LinkedIn account with an active **Sales Navigator** seat. See [docs/ACCOUNT-SETUP.md § Sales Navigator](docs/ACCOUNT-SETUP.md#sales-navigator-account).

```bash
cp accounts/salesnav.env.example accounts/salesnav.env && nano accounts/salesnav.env   # PROXY_SERVER
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=salesnav/' .env
mkdir -p data/salesnav && sudo podman run --rm -v "$PWD/data/salesnav:/x:z" docker.io/library/postgres:17 chown 1000:1000 /x   # browser runs as container uid 1000
sudo scripts/compose.sh up -d --build li-salesnav
sudo scripts/salesnav-password.sh           # prints the page password for the owner
```

The owner opens `https://SALESNAV_LOGIN_DOMAIN/vnc.html`, logs in to Sales Navigator once in the browser shown, and closes the tab. The browser keeps running, and the MCP server drives that same logged-in browser.

## 6. Connect n8n (same AWS instance)

**a. Network.** Nothing to do: the MCP services join n8n's `n8n-production_n8n-net`, so n8n reaches them by name. No traffic goes through Nginx.

Check from inside n8n: `sudo podman exec <n8n-container> wget -S -O- http://li-profile-acct-a:8080/mcp 2>&1 | head -2` should show an `HTTP/1.1 4xx` line. Any HTTP status proves the network works; `bad address` means it does not.

**b. Create credentials in n8n** (Settings → Credentials):

| Credential | Type | Values |
|---|---|---|
| `LinkedIn Postgres` | Postgres | Host: n8n's Postgres name on `n8n-production_n8n-net` (the same host n8n's own DB uses, e.g. `n8n-postgres`), Port `5432`, Database/User/Password from `.env` (`PG_DB`, `PG_USER`, `PG_PASSWORD`), SSL off |
| `Anthropic` | Anthropic API | your Anthropic API key |
| `SMTP` | SMTP | for health alerts (or swap the "Alert admin" node for Gmail or Slack) |

**c. Import the workflows** (Workflows → Import from File) from `n8n/`:

| File | What it does | Edit after import |
|---|---|---|
| `linkedin-profile-ingest.json` | `POST /webhook/linkedin-profile` with `{"url": "...", "force": false}`: cache check (90 days), daily cap, 30–90 s random pause, scrape, Claude extraction, upsert, returns the profile | **Config** node: `account`, `endpoint`, `dailyCap` |
| `csr-lead-discovery.json` | `POST /webhook/csr-leads` with `{"company": "...", "cin": "..."}`: two Sales Navigator searches (CSR/ESG/Foundation, then HR), Claude scores the leads, saves those scoring 5 or more | keyword lists in **Config** if needed |
| `linkedin-account-health.json` | every 2 h: checks each account's session and emails the fix command when one is logged out | **Accounts** list, the emails in **Alert admin** |

In each imported workflow, open every red node and pick the matching credential. Then activate the workflow.

The MCP Client nodes use **HTTP Streamable** transport with no auth (the network is private). Endpoints:

| Service | n8n endpoint |
|---|---|
| profile account `acct-a` | `http://li-profile-acct-a:8080/mcp` |
| Sales Navigator | `http://li-salesnav:8000/mcp` |

**d. Test:**

```bash
curl -s -X POST https://<n8n-domain>/webhook/linkedin-profile \
  -H 'Content-Type: application/json' -d '{"url":"https://www.linkedin.com/in/williamhgates/"}' | jq
```

The first call takes about 1–3 minutes (pause plus scrape). Repeating it returns `"source": "cache"` straight away.

Use the webhooks from your research agents (n8n "Execute Workflow" or HTTP Request nodes). They return JSON and also persist it.

## 7. Connect Claude

```bash
claude mcp add --transport http linkedin https://li-mcp.yourorg.com/li-profile-acct-a/mcp \
  --header "Authorization: Bearer <MCP_BEARER_TOKEN>"
claude mcp add --transport http salesnav https://li-mcp.yourorg.com/li-salesnav/mcp \
  --header "Authorization: Bearer <MCP_BEARER_TOKEN>"
```

Use Claude for one-off lookups. Send bulk work through the n8n webhooks so the cache, the caps and the database stay in one place. Direct Claude calls are **not** cached or counted.

## 8. Querying the data

```sql
-- everyone who ever held a CSR-ish role at a company
select p.full_name, e.title, e.start_date, e.end_date, p.linkedin_url
from linkedin.employment e join linkedin.person p on p.id = e.person_id
where lower(e.company_name) like '%tata steel%' and e.title ~* 'csr|sustainab|foundation|esg';

-- full profile as JSON (what the webhook returns)
select profile from linkedin.fresh_profile('https://www.linkedin.com/in/<id>/', 36500);

-- today's usage per account
select account, tool, count(*) filter (where ok) ok, count(*) filter (where not ok) failed
from linkedin.scrape_log where at > date_trunc('day', now()) group by 1, 2;
```

Tables: `person` (one row per profile, plus the `raw` scraped text), `employment` and `education` (one row per job and per degree, any count), `csr_lead`, `scrape_log`.

## 9. Operations

**Limits (starting points; lower them if LinkedIn shows warnings):**

| Account | Cap | Where it is set |
|---|---|---|
| Profile account | 80 profile visits/day, random 30–90 s gap | `dailyCap` in the ingest workflow's Config node |
| Sales Navigator | 30 searches/day, 80 lead views/day | `SN_DAILY_*` in `.env` (enforced by the server) |

Warm up new accounts: about 20/day in week 1, then raise the cap gradually.

**Adding capacity.** Run `sudo scripts/add-account.sh acct-b` and then `sudo scripts/install-nginx.sh`. In n8n, duplicate the ingest workflow, change the webhook path and the Config node (`acct-b`, `http://li-profile-acct-b:8080/mcp`), and add the account to the health workflow's Accounts list.
*(shortcut: one workflow per account. When there are more than about 3 accounts, add round-robin selection in a shared Config.)*

**Logged out?** The health workflow emails you the fix. To do it by hand:

```bash
sudo scripts/add-account.sh acct-a --relogin    # new link + password for the owner
```

If logouts repeat, work through this checklist:
1. Does the proxy still give the **same IP**? Check with `curl -x <proxy> https://api.ipify.org`, twice, an hour apart. A changing IP is the most common cause.
2. Is someone also using that account in their own browser or phone app *heavily* at the same time? Normal phone use is fine. Running a second automation is not.
3. Is the `data/<acct>/` directory intact and owned by the container user? `add-account.sh` fixes ownership.
4. Did volume spike? Look at `scrape_log` for the last 24 h.
5. Upgrade the image. LinkedIn changes break scrapers. Bump `LI_PROFILE_IMAGE` in `.env` and run `sudo scripts/compose.sh up -d`.

**Upgrades.** Images are pinned: `LI_PROFILE_IMAGE` in `.env`, and `LSN_REF` (commit) in `salesnav/Dockerfile`. Test a new version on one account first.

**Backups.** Run `sudo podman exec <postgres-container> pg_dump -U <PG_USER> <PG_DB> > linkedin.sql`, or include the `PG_DB` database in n8n's Postgres backups. The `data/<acct>/` directories only hold sessions and can be recreated by logging in again.

## Repo layout

```
docker-compose.yml            base stack: Sales Navigator, joins n8n-production_n8n-net
docker-compose.accounts.yml   per-account profile services (written by add-account.sh, gitignored)
.env.example                  settings; copy to .env
accounts/                     per-account proxy settings (*.env gitignored)
salesnav/                     Sales Navigator image: Chromium + noVNC + MCP server + HTTP gateway
db/schema.sql                 tables + functions (upsert, cache, caps), loaded into n8n's Postgres in step 2
nginx/                        Nginx template; rendered output + password files are gitignored
scripts/compose.sh            podman compose with both files + profiles from .env
scripts/add-account.sh        add or re-login a profile account (owner gets a link)
scripts/install-nginx.sh      render + install Nginx routes
scripts/mcp-call.sh           call any MCP tool from the shell (debugging)
scripts/salesnav-password.sh  set the Sales Navigator page password
n8n/                          workflows to import
docs/                         account setup (admin) and owner guide
```
