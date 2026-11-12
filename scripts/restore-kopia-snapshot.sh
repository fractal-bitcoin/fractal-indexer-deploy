#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/restore-kopia-snapshot.sh --height=<height> --dataset=<dataset> --target=<target-dir> [--no-delete-extra]

Required arguments:
  --height=<height>       Snapshot height to restore.
  --dataset=<dataset>     Dataset tag, for example fractald-blocks.
  --target=<target-dir>   Local restore target directory.

Options:
  --no-delete-extra        Keep extra files in the target directory.

Available datasets:
  fractald-blocks         Suggested target: fractald/data/blocks
  fractald-chainstate     Suggested target: fractald/data/chainstate
  fractal-indexer-data    Suggested target: fractal-indexer/data

Snapshot restore environment:
  KOPIA_R2_ACCESS_KEY_ID       Read-only Cloudflare R2 access key; defaults to bundled read-only key.
  KOPIA_R2_SECRET_ACCESS_KEY   Read-only Cloudflare R2 secret key; defaults to bundled read-only key.
EOF
}

snapshot_height=""
dataset=""
target=""
delete_extra=1
original_args=("$@")

while [ "$#" -gt 0 ]; do
  case "$1" in
    --height=*)
      snapshot_height="${1#--height=}"
      ;;
    --dataset=*)
      dataset="${1#--dataset=}"
      ;;
    --target=*)
      target="${1#--target=}"
      ;;
    --no-delete-extra)
      delete_extra=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
  shift
done

if [ -z "$snapshot_height" ]; then
  usage_error "missing required argument: --height"
fi

if ! is_numeric "$snapshot_height"; then
  usage_error "height must be numeric"
fi

if [ -z "$dataset" ]; then
  usage_error "missing required argument: --dataset"
fi

if [ -z "$target" ]; then
  usage_error "missing required argument: --target"
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  require_command sudo
  log "Re-running restore script as root via sudo"
  exec sudo -E bash "$0" "${original_args[@]}"
fi

load_default_readonly_r2_credentials

require_command kopia
require_command jq

log "Connecting Kopia repository as read-only"
kopia_connect_s3 readonly

kopia_restore_snapshot_dataset "$snapshot_height" "$dataset" "$target" "$delete_extra"
object_id="$KOPIA_RESTORED_OBJECT_ID"

printf '%s\t%s\t%s\t%s\n' "$snapshot_height" "$dataset" "$object_id" "$target"
