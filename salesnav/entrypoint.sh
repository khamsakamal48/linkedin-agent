#!/bin/sh
set -eu

# Xvfb and Chromium leave lock files behind when the container is stopped or killed.
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
rm -f /data/chrome/SingletonLock /data/chrome/SingletonSocket /data/chrome/SingletonCookie

Xvfb :99 -screen 0 1280x900x24 -nolisten tcp &
sleep 1

# Chromium cannot pass proxy credentials on the command line, so PROXY_SERVER
# must be an IP-whitelisted endpoint (whitelist the server's public IP at the provider).
PROXY_ARG=""
[ -n "${PROXY_SERVER:-}" ] && PROXY_ARG="--proxy-server=${PROXY_SERVER}"

# --no-sandbox: Chromium's sandbox needs privileges Podman does not grant by default.
chromium --no-sandbox --no-first-run --no-default-browser-check \
  --user-data-dir=/data/chrome \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 \
  --window-size=1280,900 --start-maximized \
  ${PROXY_ARG} \
  https://www.linkedin.com/sales/home >/tmp/chromium.log 2>&1 &

# VNC is unauthenticated on purpose; it only listens inside the container and
# is published to the host's loopback, where Nginx adds basic auth.
x11vnc -display :99 -forever -shared -nopw -quiet -rfbport 5900 -localhost &
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 >/tmp/novnc.log 2>&1 &

# Wait for Chromium's CDP endpoint before accepting MCP traffic.
i=0
until node -e "fetch('http://127.0.0.1:9222/json/version').then(()=>process.exit(0),()=>process.exit(1))"; do
  i=$((i+1)); [ "$i" -gt 30 ] && { echo "chromium did not start"; cat /tmp/chromium.log; exit 1; }
  sleep 1
done

# Read-only tools only: InMail and lead-list writes are refused at the gateway
# (the server itself treats a daily cap of 0 as unlimited, so caps cannot disable them).
exec supergateway --stdio "node /app/dist/index.js" \
  --tools linkedin_session_status --tools linkedin_search_leads --tools linkedin_get_lead_profile \
  --tools linkedin_list_lead_lists --tools linkedin_export_leads \
  --outputTransport streamableHttp --stateful --sessionTimeout 900000 \
  --port 8000 --healthEndpoint /healthz
