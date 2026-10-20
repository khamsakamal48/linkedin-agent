# Sales Navigator MCP: a real Chromium on a virtual display (watchable / loggable-in
# through noVNC), the globodai Sales Navigator server attached to it over CDP,
# and supergateway exposing that stdio server as streamable HTTP on :8000.
FROM docker.io/library/node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      chromium xvfb x11vnc novnc websockify git ca-certificates fonts-liberation tini \
 && rm -rf /var/lib/apt/lists/*

# Pinned upstream commit (its npm package is only a placeholder). Bump deliberately.
ARG LSN_REF=2e158e74c8cb593c85b8372b29586519def01b1b
RUN git clone https://github.com/globodai-group/mcp-linkedin-sales-navigator.git /app \
 && cd /app && git checkout "$LSN_REF" \
 && npm ci && npm run build && npm prune --omit=dev

RUN npm install -g supergateway@4.2.0

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /data && chown node:node /data

USER node
ENV DISPLAY=:99 \
    LSN_AUTH_METHOD=cdp \
    LSN_CDP_ENDPOINT=http://127.0.0.1:9222 \
    LSN_USAGE_FILE=/data/usage.json

VOLUME /data
EXPOSE 8000 6080
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
