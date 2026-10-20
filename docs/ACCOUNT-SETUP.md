# Setting up LinkedIn accounts (admin guide)

This is for whoever runs the AWS server. The account owner does **not** need server access, a terminal, or any technical knowledge. They receive a link and a password, then log in to LinkedIn as usual. Send them [OWNER-GUIDE.md](OWNER-GUIDE.md).

## How it works

```
admin: scripts/add-account.sh acct-a
          │  starts a one-off browser on the server, behind acct-a's proxy
          ▼
owner: opens https://LOGIN_DOMAIN/vnc_lite.html#... (+ password)
          │  sees a LinkedIn login page, signs in, approves 2FA
          ▼
server: saves the session cookies in data/acct-a/, closes the login browser,
        starts li-profile-acct-a, which reuses the same session, proxy and IP
```

Why this design:
- **The password never leaves the owner.** It is typed straight into LinkedIn and is never stored. Only the session is kept.
- **Same IP for login and scraping.** The login goes through the account's own proxy. A session created on a laptop and then used from a server is the main cause of the "logged out all the time" problem.
- **The link is single-use.** The page password changes for every login, the page closes as soon as the login finishes, and it closes anyway after 30 minutes.

## Before the first account (once)

1. Finish README steps 1–2 (install, `.env`, Postgres).
2. Run `sudo scripts/install-nginx.sh` and `sudo certbot --nginx -d <MCP_DOMAIN> -d <LOGIN_DOMAIN> -d <SALESNAV_LOGIN_DOMAIN>`.
3. Open `https://<LOGIN_DOMAIN>/` in a browser. It should ask for a password and reject every attempt. That is correct: no login is running.

## Adding a profile-scraping account

Pick a short name: lowercase letters, digits and dashes, for example `acct-a`, `priya`, `research-2`.

```bash
cd /opt/linkedin-agent
scripts/add-account.sh acct-a
```

1. **Proxy questions.** Paste the sticky proxy details from the provider dashboard:
   ```
   PROXY_SERVER (e.g. http://gate.provider.com:7000): http://gate.smartproxy.com:7000
   PROXY_USERNAME: user-abc-session-acct-a-sessTime-1440
   PROXY_PASSWORD: ********
   ```
   - Most providers make a session sticky through the username (for example `-session-<id>`). Give each account its **own** session id, and set the longest session time offered.
   - Pick a proxy location in the same country/city the account owner normally uses.
   - Testing with your own account: you can leave all three empty. The login then comes from the AWS IP. This works, but LinkedIn may ask for extra verification.
   - The values are saved to `accounts/acct-a.env` (permissions 600, never committed).
2. The script adds a `li-profile-acct-a` service to `docker-compose.accounts.yml` and prints its ports.
3. It starts the login browser and prints a block like this:
   ```
   ================ SEND THIS TO THE ACCOUNT OWNER ================
   Link:      https://li-login.yourorg.com/vnc_lite.html#?path=websockify%3Ftoken%3D...&scale=true
   Username:  owner
   Password:  <password printed by the script>
   ...
   ```
   **Copy the whole link.** The part after `#` is the access token, so the link fails without it. Send the link and the password through separate channels if you can (for example the link by email and the password by WhatsApp or a call).
4. Leave the terminal open. The script waits. The owner follows [OWNER-GUIDE.md](OWNER-GUIDE.md).
   *Testing with your own account:* open the link yourself and do the owner steps.
   You can also watch the login live. Open the same link: two viewers can share the screen. This helps when guiding the owner over a call.
5. When the owner reaches their LinkedIn feed, the login browser saves the session and exits. The script prints `Logged in. li-profile-acct-a is running.`
6. Publish the MCP route and verify:
   ```bash
   sudo scripts/install-nginx.sh && sudo certbot --nginx   # certbot again because the file was re-rendered
   scripts/mcp-call.sh http://127.0.0.1:8201/mcp get_my_profile '{}'
   ```
   `get_my_profile` should return the owner's own profile text.
7. In n8n, add the account to the health workflow's **Accounts** list. Point an ingest workflow at it (README §9 "Adding capacity").

### If something goes wrong

| Symptom | Fix |
|---|---|
| Script prints `Login viewer did not start` and some logs | Usually a proxy problem. Check the proxy: `curl -x http://user:pass@host:port https://api.ipify.org`. Fix `accounts/acct-a.env`, then run `scripts/add-account.sh acct-a --relogin`. |
| Owner gets "401 Authorization Required" | Wrong password, or the login already finished or timed out. Run `--relogin` for a fresh link. |
| Owner sees a black or grey screen | Wait 10 seconds and reload. If it persists, check `docker logs li-login`. |
| `Login did not complete (exit …)` | The owner closed the tab before reaching the feed, or 30 minutes passed. Run `--relogin`. |
| LinkedIn shows "Let's do a quick security check" / CAPTCHA | Normal for a new IP. The owner completes it in the same window. |
| LinkedIn says the account is restricted | Stop using that account. Lower the caps. Ask the owner to resolve it on linkedin.com from their own device. |

## Re-login (account got logged out)

The health workflow emails you when a session is gone. The fix is always:

```bash
scripts/add-account.sh acct-a --relogin
```

This stops that account's server, prints a fresh link and password, and restarts the server when the owner is done. The proxy settings are kept.

## Changing an account's proxy

Edit `accounts/acct-a.env`, then **run `--relogin`**. A session moved to a new IP without logging in again usually triggers a LinkedIn checkpoint.

## Removing an account

```bash
docker compose rm -sf li-profile-acct-a
# delete the li-profile-acct-a block from docker-compose.accounts.yml
rm -rf data/acct-a accounts/acct-a.env      # deletes the stored session
sudo scripts/install-nginx.sh
```

Also remove it from the n8n health and ingest workflows. Tell the owner they can also sign out all sessions from LinkedIn → Settings → Sign in & security → Where you're signed in.

## Sales Navigator account

The Sales Navigator server works differently: a real Chromium browser runs permanently on the server, and the owner logs in to that browser once. Requirements:
- The account has an active **Sales Navigator** seat.
- The proxy is an **IP-whitelisted** endpoint. Chromium cannot send a proxy username/password, so in the provider dashboard whitelist the EC2 public IP (`curl https://api.ipify.org` on the server) and copy the host:port of a sticky session.

Steps:

```bash
cp accounts/salesnav.env.example accounts/salesnav.env
nano accounts/salesnav.env                    # PROXY_SERVER=http://host:port
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=salesnav/' .env
mkdir -p data/salesnav && sudo chown 1000:1000 data/salesnav   # browser runs as uid 1000
docker compose up -d --build li-salesnav      # first build takes a few minutes
scripts/salesnav-password.sh                  # prints username "owner" + a password
```

1. Send the owner `https://<SALESNAV_LOGIN_DOMAIN>/vnc.html` and the password. They click **Connect**, see a browser showing LinkedIn, log in, open Sales Navigator once, and close the tab. Steps are in the owner guide.
2. Verify: `scripts/mcp-call.sh http://127.0.0.1:8100/mcp linkedin_session_status '{}'` should report an authenticated session.
3. The page stays available, so you can open it at any time to **watch** the searches run. Rotate its password with `scripts/salesnav-password.sh` when the owner no longer needs it.

Re-login is the same: send the page again and the owner logs in inside the same browser. No restart is needed.

The server enforces its own daily budgets (`SN_DAILY_SEARCHES`, `SN_DAILY_PROFILE_VIEWS` in `.env`; restart `li-salesnav` after a change). Only read-only tools are exposed: InMail sending and lead-list writes are blocked in `salesnav/entrypoint.sh`.
