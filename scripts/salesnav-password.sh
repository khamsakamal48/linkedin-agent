#!/usr/bin/env bash
# Set the password for the Sales Navigator browser page and print it.
set -euo pipefail
cd "$(dirname "$0")/.."
pw=$(openssl rand -base64 12 | tr -d '/+=')
printf 'owner:%s\n' "$(openssl passwd -apr1 "$pw")" > nginx/.htpasswd-salesnav
echo "Username: owner"; echo "Password: $pw"
