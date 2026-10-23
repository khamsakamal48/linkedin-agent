#!/usr/bin/env bash
# Add a LinkedIn profile-scraping account, or log one in again.
#
#   scripts/add-account.sh acct-a            # new account: asks for its proxy, then login
#   scripts/add-account.sh acct-a --relogin  # existing account was logged out
#
# Prints a link + password for the account owner. The owner signs in to LinkedIn
# inside a browser running on this server (through this account's proxy), so the
# password never reaches us and the login IP matches the IP used for scraping.
set -euo pipefail
cd "$(dirname "$0")/.."

acct=${1:?usage: add-account.sh <account-name> [--relogin]}
mode=${2:-new}
[[ "$acct" =~ ^[a-z0-9-]+$ ]] || { echo "account name: lowercase letters, digits, dashes only"; exit 1; }

[[ -f .env ]] || { echo ".env missing: cp .env.example .env and fill it in first"; exit 1; }
set -a; . ./.env; set +a
: "${LI_PROFILE_IMAGE:?set in .env}" "${LOGIN_DOMAIN:?set in .env}"

svc="li-profile-$acct"
envf="accounts/$acct.env"
datadir="data/$acct"
accounts_yml=docker-compose.accounts.yml
[[ -f $accounts_yml ]] || cp docker-compose.accounts.yml.example "$accounts_yml"

if [[ "$mode" == new ]]; then
  [[ -f "$envf" ]] && { echo "$envf exists; use --relogin"; exit 1; }
  echo "Proxy for $acct (sticky residential/ISP session, one per account; empty = none)."
  read -rp "  PROXY_SERVER (e.g. http://gate.provider.com:7000): " proxy
  read -rp "  PROXY_USERNAME: " puser
  read -rsp "  PROXY_PASSWORD: " ppass; echo
  umask 077
  printf 'PROXY_SERVER=%s\nPROXY_USERNAME=%s\nPROXY_PASSWORD=%s\n' "$proxy" "$puser" "$ppass" > "$envf"
  umask 022

  # Next free host port from 8201 up, published on loopback for scripts/mcp-call.sh checks.
  port=8201
  while grep -q "127.0.0.1:$port:" "$accounts_yml"; do port=$((port+1)); done
  # Replace the empty map on first use, then append the service.
  sed -i 's/^services: {}$/services:/' "$accounts_yml"
  cat >> "$accounts_yml" <<EOF
  $svc:
    image: \${LI_PROFILE_IMAGE}
    restart: unless-stopped
    env_file: [$envf]
    environment:
      LOG_LEVEL: WARNING
      EXPERIMENTAL_PERSIST_DERIVED_RUNTIME: "true"
      # n8n reaches this service by its compose name; mcp-call.sh uses localhost.
      FASTMCP_HTTP_ALLOWED_HOSTS: '["$svc","$svc:8080","localhost","localhost:8080"]'
    volumes:
      - ./$datadir:/home/pwuser/.linkedin-mcp:z
    ports:
      - "127.0.0.1:$port:8080"
    command: ["--transport", "streamable-http", "--host", "0.0.0.0", "--port", "8080", "--path", "/mcp"]
    shm_size: 1gb
    networks: [linkedin]
EOF
  echo "Added $svc on 127.0.0.1:$port (n8n: http://$svc:8080/mcp)"
else
  [[ -f "$envf" ]] || { echo "$envf not found; run without --relogin first"; exit 1; }
fi

# The container user must own the session directory.
mkdir -p "$datadir"
podman run --rm --user root --entrypoint chown -v "$PWD/$datadir:/x:z" "$LI_PROFILE_IMAGE" -R pwuser:pwuser /x

# The running server and the login must not share the profile at the same time.
bash scripts/compose.sh stop "$svc" >/dev/null 2>&1 || true
podman rm -f li-login >/dev/null 2>&1 || true

# Fresh one-time password for the login page (Nginx re-reads this file per request).
pw=$(openssl rand -base64 12 | tr -d '/+=')
printf 'owner:%s\n' "$(openssl passwd -apr1 "$pw")" > nginx/.htpasswd-login

podman run -d --name li-login --env-file "$envf" \
  -v "$PWD/$datadir:/home/pwuser/.linkedin-mcp:z" \
  -p 127.0.0.1:6080:6080 --shm-size 1g \
  "$LI_PROFILE_IMAGE" --login --login-viewer >/dev/null

echo "Starting the login browser..."
link=""
for _ in $(seq 1 90); do
  link=$(podman logs li-login 2>&1 | grep -o 'http://127.0.0.1:6080/vnc_lite.html[^[:space:]]*' | tail -1 || true)
  [[ -n "$link" ]] && break
  podman ps -q -f name=^li-login$ | grep -q . || break
  sleep 2
done
if [[ -z "$link" ]]; then
  echo "Login viewer did not start:"; podman logs li-login 2>&1 | tail -20; podman rm -f li-login >/dev/null; exit 1
fi
link=${link/http:\/\/127.0.0.1:6080/https://$LOGIN_DOMAIN}

cat <<EOF

================ SEND THIS TO THE ACCOUNT OWNER ================
Link:      $link
Username:  owner
Password:  $pw

Open the link, sign in to LinkedIn in the window shown, approve any
phone / 2FA prompt, wait until the LinkedIn feed appears, then close the tab.
The link works once and expires in 30 minutes.
================================================================

Waiting for the owner to finish (Ctrl+C is safe; re-run with --relogin)...
EOF

code=$(podman wait li-login)
podman logs li-login 2>&1 | tail -5
podman rm li-login >/dev/null
: > nginx/.htpasswd-login   # disable the login page again

if [[ "$code" != 0 ]]; then
  echo "Login did not complete (exit $code). Re-run: scripts/add-account.sh $acct --relogin"; exit 1
fi

bash scripts/compose.sh up -d "$svc"

# The login exits 0 even when it was abandoned, so prove the session with one real call.
url="http://127.0.0.1:$(bash scripts/compose.sh port "$svc" 8080 | cut -d: -f2)/mcp"
for _ in $(seq 1 30); do curl -s -o /dev/null "$url" && break; sleep 2; done
echo "Checking the session (opens the owner's own profile once)..."
result=$(bash scripts/mcp-call.sh "$url" get_my_profile '{}' || true)
if [[ -z "$result" || "$result" == *'"isError":true'* || "$result" == *'"error"'* ]]; then
  echo "${result:0:400}"
  echo "NOT logged in. Re-run: scripts/add-account.sh $acct --relogin"; exit 1
fi
echo "Logged in. $svc is running at $url (n8n: http://$svc:8080/mcp)"
