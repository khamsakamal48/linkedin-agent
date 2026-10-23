#!/usr/bin/env bash
# Render the Nginx site (login pages only) from .env and reload Nginx.
#   sudo scripts/install-nginx.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${LOGIN_DOMAIN:?}" "${SALESNAV_LOGIN_DOMAIN:?}"
export REPO_DIR=$PWD

mkdir -p nginx/rendered
touch nginx/.htpasswd-login          # empty = login page refuses everyone
[[ -f nginx/.htpasswd-salesnav ]] || touch nginx/.htpasswd-salesnav

vars='${LOGIN_DOMAIN} ${SALESNAV_LOGIN_DOMAIN} ${REPO_DIR}'
envsubst "$vars" < nginx/linkedin-agent.conf.tmpl > nginx/rendered/linkedin-agent.conf

ln -sf "$REPO_DIR/nginx/rendered/linkedin-agent.conf" /etc/nginx/conf.d/linkedin-agent.conf
# SELinux (Fedora) blocks Nginx from proxying to 127.0.0.1:<port> unless this is on.
if command -v selinuxenabled >/dev/null && selinuxenabled; then setsebool -P httpd_can_network_connect 1; fi
nginx -t
systemctl reload nginx
