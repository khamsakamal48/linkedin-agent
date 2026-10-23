#!/usr/bin/env bash
# Call one MCP tool over streamable HTTP and print the JSON-RPC result.
#   scripts/mcp-call.sh http://127.0.0.1:8201/mcp tools/list
#   scripts/mcp-call.sh http://127.0.0.1:8201/mcp get_my_profile '{}'
set -euo pipefail
url=${1:?usage: mcp-call.sh <url> <tool|tools/list> [json-args]}
tool=${2:?tool name or tools/list}
args=${3:-{\}}

hdrs=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

# Streamable HTTP answers either plain JSON or SSE; keep only the JSON payload.
rpc() { curl -sS --max-time "${MCP_TIMEOUT:-240}" "${hdrs[@]}" "$@" "$url" | sed -n 's/^data: //p; t; /^{/p'; }

rpc -D "$tmp" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp-call","version":"1"}}}' >/dev/null
sid=$(grep -i '^mcp-session-id:' "$tmp" | cut -d' ' -f2 | tr -d '\r' || true)
[[ -n "$sid" ]] && hdrs+=(-H "Mcp-Session-Id: $sid")
rpc -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

if [[ "$tool" == tools/list ]]; then
  rpc -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
else
  rpc -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}"
fi
