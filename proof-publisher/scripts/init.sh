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
mkdir -p data
sudo chown -R 10001:10001 data
)
