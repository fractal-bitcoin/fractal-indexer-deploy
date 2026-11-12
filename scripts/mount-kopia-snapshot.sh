#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/mount-kopia-snapshot.sh <height> <target-dir>

Mounts snapshot datasets under <target-dir>:
  fractald/blocks
  fractald/chainstate
  fractal-indexer/data

Example:
  scripts/mount-kopia-snapshot.sh 1820067 snapshot/1820067
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 2 ]; then
  usage_error "expected height and target directory"
fi

snapshot_height="$1"
target_root="$2"

if ! is_numeric "$snapshot_height"; then
  usage_error "height must be numeric"
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  require_command sudo
  log "Re-running mount script as root via sudo"
  exec sudo -E bash "$0" "$snapshot_height" "$target_root"
fi

ensure_fuse_available() {
  if command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1; then
    return
  fi

  cat >&2 <<'EOF'
FUSE is required to mount Kopia snapshots.

Install it manually, then rerun this script:
  Debian/Ubuntu:              sudo apt-get install fuse3
  CentOS/RHEL/Amazon Linux:   sudo yum install fuse3
EOF
  exit 1
}

unmount_path() {
  local path="$1"

  if mountpoint -q "$path"; then
    if command -v fusermount3 >/dev/null 2>&1; then
      fusermount3 -u "$path" >/dev/null 2>&1 && return
    fi

    if command -v fusermount >/dev/null 2>&1; then
      fusermount -u "$path" >/dev/null 2>&1 && return
    fi

    umount "$path"
  fi
}

# Track only mounts successfully created by this invocation.
mounted_paths=()
cleanup_started=false

cleanup() {
  local i

  if [ "$cleanup_started" = true ]; then
    return
  fi

  cleanup_started=true
  # Signal handlers and EXIT can both reach cleanup; run it only once.
  trap '' INT TERM
  set +e

  for ((i = ${#mounted_paths[@]} - 1; i >= 0; i--)); do
    unmount_path "${mounted_paths[$i]}"
  done

  mounted_paths=()
}

wait_for_mount() {
  local target="$1"
  local mount_pid="$2"
  local i

  for i in $(seq 1 60); do
    if mountpoint -q "$target"; then
      return 0
    fi

    if ! kill -0 "$mount_pid" >/dev/null 2>&1; then
      return 1
    fi

    sleep 1
  done

  return 1
}

snapshot_object_id() {
  local dataset="$1"
  kopia_snapshot_object_id \
    "network:fractal" \
    "role:snapshot" \
    "dataset:${dataset}" \
    "height:${snapshot_height}" \
    "dbschema:${SNAPSHOT_SCHEMA_VERSION}"
}

mount_dataset() {
  local dataset="$1"
  local target="$2"
  local object_id mount_pid

  object_id="$(snapshot_object_id "$dataset")"
  mkdir -p "$target"

  if mountpoint -q "$target"; then
    die "${target} is already a mount point"
  fi

  log "Mounting ${dataset} (${object_id}) to ${target}"
  kopia mount "$object_id" "$target" --fuse-allow-other &
  mount_pid="$!"

  if ! wait_for_mount "$target" "$mount_pid"; then
    die "failed to mount ${dataset} to ${target}"
  fi

  mounted_paths+=("$target")
}

load_default_readonly_r2_credentials
require_command kopia
require_command jq
require_command mountpoint
ensure_fuse_available

log "Connecting Kopia repository as read-only"
kopia_connect_s3 readonly

trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

mount_dataset fractald-blocks "${target_root}/fractald/blocks"
mount_dataset fractald-chainstate "${target_root}/fractald/chainstate"
mount_dataset fractal-indexer-data "${target_root}/fractal-indexer/data"

cat <<EOF

Snapshots mounted under ${target_root}

Press Ctrl+C to unmount.
EOF

while true; do
  sleep 3600
done
