#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/restore-kopia-snapshot.sh --height=<height> --dataset=<dataset> --target=<target-dir> [--no-delete-extra] [--no-skip-existing] [--yes]

Required arguments:
  --height=<height>       Snapshot height to restore.
  --dataset=<dataset>     Dataset tag, for example fractald-blocks.
  --target=<target-dir>   Local restore target directory.

Options:
  --no-delete-extra        Keep extra files in the target directory.
  --no-skip-existing       Restore existing files and symlinks instead of skipping them.
  --yes                    Skip deletion/overwrite confirmation for a nonempty target.

Existing files are skipped by default. Resume only the same snapshot this way;
use a new directory or --no-skip-existing when switching snapshots.

Targets are resolved with GNU realpath. The filesystem root is rejected,
even with --yes or --no-delete-extra.

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
skip_existing=1
assume_yes=0
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
    --no-skip-existing)
      skip_existing=0
      ;;
    --yes)
      assume_yes=1
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

validate_restore_target() {
  target="$(realpath -m -- "$target")" || die "cannot resolve restore target"
  [ "$target" != / ] || die "unsafe restore target: ${target}"
  if [ -e "$target" ] && [ ! -d "$target" ]; then
    die "restore target is not a directory: ${target}"
  fi
}

confirm_restore_target() {
  local first_entry answer

  if [ "$delete_extra" -eq 0 ] && [ "$skip_existing" -eq 1 ]; then
    return 0
  fi
  [ -d "$target" ] || return 0
  first_entry="$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" || die "cannot inspect restore target"
  [ -n "$first_entry" ] || return 0

  warn "Restoring ${dataset} at height ${snapshot_height} to ${target}. Back up this directory before continuing."
  if [ "$delete_extra" -eq 1 ]; then
    warn "files absent from the snapshot will be deleted."
  fi
  if [ "$skip_existing" -eq 0 ]; then
    warn "Existing files and symlinks may be overwritten because --no-skip-existing was provided."
  fi
  [ "$assume_yes" -eq 0 ] || return 0
  [ -t 0 ] || die "nonempty target requires interactive confirmation; use --yes to accept the requested changes"
  printf 'Type the full target path "%s" to continue: ' "$target" >&2
  read -r answer || die "confirmation failed; restore cancelled"
  [ "$answer" = "$target" ] || die "confirmation failed; restore cancelled"
}

require_command realpath
require_command find
validate_restore_target
confirm_restore_target

load_default_readonly_r2_credentials

require_command kopia
require_command jq

log "Connecting Kopia repository as read-only"
kopia_connect_s3 readonly

kopia_restore_snapshot_dataset "$snapshot_height" "$dataset" "$target" "$delete_extra" "" "$skip_existing"
object_id="$KOPIA_RESTORED_OBJECT_ID"

printf '%s\t%s\t%s\t%s\n' "$snapshot_height" "$dataset" "$object_id" "$target"
