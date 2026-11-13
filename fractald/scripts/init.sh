#!/bin/bash
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [ "$(pwd -P)" != "$SERVICE_DIR" ]; then
  printf 'ERROR: run this script from the service directory: %s\n' "$SERVICE_DIR" >&2
  printf 'First run: cd "%s"\n' "$SERVICE_DIR" >&2
  exit 1
fi

NETWORK_NAME="fractal-indexer-fip101-net"
docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null

echo ">>> Init Directory"
(
set -x
mkdir -p data conf
test -f conf/bitcoin.conf || cp conf/bitcoin.conf.example conf/bitcoin.conf
sudo chown -R 1000:1000 data
)

if grep -q "REPLACE_RPC_" conf/bitcoin.conf; then
  cat <<'MSG'
>>> Update conf/bitcoin.conf before starting fractald.
    Set rpcuser and rpcpassword to non-placeholder values.
MSG
fi
