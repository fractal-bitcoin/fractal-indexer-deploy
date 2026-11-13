#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/cleanup.sh --stop
  scripts/cleanup.sh --data
  scripts/cleanup.sh --all

Options:
  --stop    Stop all Docker Compose services managed by this repository.
  --data    Stop services and delete runtime data directories. Requires typing: data
            Includes proof-publisher/data/ and its SQLite state. Back it up first.
  --all     Stop services and delete runtime data, logs, and generated local configs.
            Includes publisher SQLite state and proof-publisher/config.json,
            which may contain the signing private key and API keys. Back them up first.
            Requires typing: all
EOF
}

mode=""
original_args=("$@")

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stop|--data|--all)
      if [ -n "$mode" ]; then
        usage_error "choose only one cleanup mode"
      fi
      mode="$1"
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

if [ -z "$mode" ]; then
  usage_error "missing cleanup mode"
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  require_command sudo
  log "Re-running cleanup script as root via sudo"
  exec sudo -E bash "$0" "${original_args[@]}"
fi

require_command docker
compose_cmd >/dev/null

stop_stack() {
  local name="$1"
  local dir="$2"

  log "Stopping ${name}"
  run_compose "$dir" down
}

stop_all() {
  stop_stack proof-publisher "${REPO_ROOT}/proof-publisher"
  stop_stack fractal-indexer "${REPO_ROOT}/fractal-indexer"
  stop_stack fractald "${REPO_ROOT}/fractald"
  log "All services stopped"
}

confirm_exact() {
  local expected="$1"
  local description="$2"
  local answer

  cat >&2 <<EOF

WARNING: ${description}
This action cannot be undone.
EOF

  if [ ! -t 0 ]; then
    die "confirmation is required; rerun interactively and type ${expected}"
  fi

  printf 'Type "%s" to continue: ' "$expected"
  read -r answer
  if [ "$answer" != "$expected" ]; then
    die "confirmation failed; cleanup cancelled"
  fi
}

remove_paths() {
  local path

  for path in "$@"; do
    if [ -e "$path" ]; then
      log "Removing ${path}"
      rm -rf "$path"
    else
      log "Skipping missing path ${path}"
    fi
  done
}

case "$mode" in
  --stop)
    stop_all
    ;;
  --data)
    confirm_exact data "runtime data directories will be deleted, including proof-publisher/data/ and its SQLite state. Back up publisher state before continuing"
    stop_all
    remove_paths \
      "${REPO_ROOT}/fractald/data" \
      "${REPO_ROOT}/fractal-indexer/data" \
      "${REPO_ROOT}/proof-publisher/data"
    log "Runtime data cleanup completed"
    ;;
  --all)
    confirm_exact all "runtime data, logs, generated configs, and local Kopia cache will be deleted. This includes proof-publisher/data/ (SQLite state) and proof-publisher/config.json (which may contain the signing private key and API keys). Back up publisher state, config, and private keys before continuing"
    stop_all
    remove_paths \
      "${REPO_ROOT}/fractald/data" \
      "${REPO_ROOT}/fractal-indexer/data" \
      "${REPO_ROOT}/proof-publisher/data" \
      "${REPO_ROOT}/fractal-indexer/logs" \
      "${REPO_ROOT}/proof-publisher/logs" \
      "${REPO_ROOT}/.kopia-cache" \
      "${REPO_ROOT}/fractald/conf/bitcoin.conf" \
      "${REPO_ROOT}/fractal-indexer/conf/indexer/chain.yaml" \
      "${REPO_ROOT}/proof-publisher/config.json"
    log "Full cleanup completed"
    ;;
esac
