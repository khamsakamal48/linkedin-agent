#!/usr/bin/env bash
# Render the Nginx site from .env + the account list and reload Nginx.
# Re-run after every add-account.sh (new account => new /<account>/mcp route).
#   sudo scripts/install-nginx.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${MCP_BEARER_TOKEN:?set MCP_BEARER_TOKEN in .env (openssl rand -hex 32)}"
: "${MCP_DOMAIN:?}" "${LOGIN_DOMAIN:?}" "${SALESNAV_LOGIN_DOMAIN:?}"
export REPO_DIR=$PWD

mkdir -p nginx/rendered
touch nginx/.htpasswd-login          # empty = login page refuses everyone
[[ -f nginx/.htpasswd-salesnav ]] || touch nginx/.htpasswd-salesnav

# One location per published MCP port: profile accounts + Sales Navigator.
loc() {  # loc <url-prefix> <host-port>
  cat <<LOC
location /$1/mcp {
    if (\$li_mcp_authorized = 0) { return 401; }
    proxy_pass http://127.0.0.1:$2/mcp;
    proxy_http_version 1.1;
    proxy_set_header Host localhost;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 300s;
}
LOC
}
{
  if [[ -f docker-compose.accounts.yml ]]; then
    # "  li-profile-acct-a:" ... "127.0.0.1:8201:8080"
    awk '/^  li-profile-/{svc=$1; sub(":","",svc)} /127.0.0.1:[0-9]+:8080/{match($0,/127.0.0.1:[0-9]+/); print svc, substr($0,RSTART+10,RLENGTH-10)}' \
      docker-compose.accounts.yml | while read -r svc port; do loc "$svc" "$port"; done
  fi
  loc li-salesnav 8100
} > nginx/rendered/mcp-locations.conf

vars='${MCP_BEARER_TOKEN} ${MCP_DOMAIN} ${LOGIN_DOMAIN} ${SALESNAV_LOGIN_DOMAIN} ${REPO_DIR}'
envsubst "$vars" < nginx/linkedin-agent.conf.tmpl > nginx/rendered/linkedin-agent.conf

ln -sf "$REPO_DIR/nginx/rendered/linkedin-agent.conf" /etc/nginx/conf.d/linkedin-agent.conf
nginx -t && systemctl reload nginx
echo "Nginx routes:"; grep -o 'location /[^ ]*' nginx/rendered/mcp-locations.conf
