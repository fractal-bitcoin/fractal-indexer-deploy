# Repository Guidelines

## Project Structure & Module Organization
This repository deploys the Fractal node and related indexing services:

- `fractald/`: Fractal node. Key files: `docker-compose.yaml`, `scripts/init.sh`, `conf/bitcoin.conf.example`.
- `fractal-indexer/`: Fractal BRC20 indexer and query API. Key files: `docker-compose.yaml`, `scripts/init.sh`, `conf/indexer/*.yaml`.
- `proof-publisher/`: optional proof submission daemon. Key files: `docker-compose.yaml`, `scripts/init.sh`, `config.example.json`.
- `scripts/`: top-level deployment helpers, including `deploy.sh`, `check-env.sh`, `install-deps.sh`, `restore-kopia-snapshot.sh`, `mount-kopia-snapshot.sh`, `list-kopia-snapshot-heights.sh`, `upload-kopia-snapshots.sh`, and `cleanup.sh`.

Runtime data and logs are created under each service directory, for example
`fractald/data/`, `fractal-indexer/data/`, and `fractal-indexer/logs/`.
Treat example config files as templates and keep generated local configs
environment-specific.

## Build, Test, and Development Commands
Use `scripts/deploy.sh` for full deployments and service-local Compose files for
manual work.

The top-level deployment generates node and indexer chain configs only.
Create, configure, and start `proof-publisher` manually as documented in README.
Run each service's `scripts/init.sh` from its service directory; it rejects an
incorrect working directory before making changes.

- `scripts/deploy.sh --snapshot=latest`: recommended one-command snapshot restore and deployment.
- `scripts/deploy.sh --snapshot=1820067`: fresh snapshot deployment at a fixed height.
- `scripts/deploy.sh --snapshot=latest --download-only`: restore snapshot data and exit before service startup.
- `scripts/deploy.sh --snapshot=1820067 --yes`: deploy with automatic warning confirmation.
- `scripts/check-env.sh --snapshot=1820067`: check dependencies, ports, memory, disk, and data directories.
- `scripts/install-deps.sh`: install missing deployment dependencies.
- `scripts/restore-kopia-snapshot.sh --height=1820067 --dataset=fractald-blocks --target=fractald/data/blocks`: restore one dataset.
- `scripts/mount-kopia-snapshot.sh 1820067 snapshot/1820067`: mount snapshot datasets; requires FUSE to be installed manually.
- `scripts/list-kopia-snapshot-heights.sh`: list uploaded heights for the current snapshot schema; the list can include incomplete dataset sets.
- `scripts/upload-kopia-snapshots.sh 1827202`: upload local datasets after stopping source containers; requires dedicated write-capable R2 credentials.
- `scripts/cleanup.sh --stop`: stop all services.
- `scripts/cleanup.sh --data`: stop services and delete runtime data after typing `data`.
- `scripts/cleanup.sh --all`: stop services and delete runtime data, logs, generated configs, and Kopia cache after typing `all`.
- `cd fractal-indexer && bash ./scripts/init.sh db`: initialize indexer tables before a non-snapshot first start.
- `docker compose ps` and `docker compose logs --tail=100 -f`: check health and troubleshoot startup from a service directory.

Snapshot restore and upload scripts use strict snapshot schema matching through
`SNAPSHOT_SCHEMA_VERSION`, currently `v1` (tag `dbschema:v1`). Keep restore,
upload, mount, and snapshot-list behavior aligned when changing this schema
version. Snapshot scripts accept `KOPIA_R2_ACCESS_KEY_ID` and
`KOPIA_R2_SECRET_ACCESS_KEY`, not generic `AWS_*` credentials.

## Coding Style & Naming Conventions
YAML and shell are the primary maintained file types here. Use 2-space
indentation in YAML. Shell scripts are Bash scripts; keep them readable, strict
with `set -euo pipefail`, and consistent with `scripts/lib.sh` helpers. Name new
config files by purpose, matching nearby patterns such as
`conf/indexer/db.yaml`, `conf/indexer/kvdb.yaml`, or `config.example.json`.
Keep container, volume, and directory names lowercase with hyphens or
underscores consistent with nearby files.

## Testing Guidelines
Run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests` for the
local mocked regression tests. For script changes, run `bash -n` on the edited
shell scripts. Validate deployment changes in an authorized environment by
running the affected stack, checking `docker compose ps`, and reviewing logs for healthcheck
or connection failures. When editing chain connectivity, verify generated
`chain.yaml` files against the target Fractal node RPC and ZMQ endpoints before
starting indexers.

All service stacks join the shared external Docker network
`fractal-indexer-fip101-net`. Internal services should communicate through
Docker DNS names such as `fractald`, `fractal-indexer`, `clickhouse`, `pika`,
and `pika-brc20`. API endpoints bind to local host access by default.
Do not publish RPC, ZMQ, database, or cache ports to the host unless explicitly
required and reviewed.

## Commit & Pull Request Guidelines
Use short imperative commit subjects, ideally scoped by area, for example
`scripts: add environment checks` or `fractald: update compose config`. PRs
should state which stack or script changed, list config, port, data, or snapshot
behavior changes, and include the exact validation commands run.

## Security & Configuration Tips
Do not commit generated configs containing real RPC credentials, signing keys, or
API keys, including `fractald/conf/bitcoin.conf`, `conf/**/chain.yaml`, and
`proof-publisher/config.json`. Review init and cleanup scripts before running
them because they can change ownership or delete runtime data. Keep generated
`data/`, `logs/`, `.kopia-cache/`, and mounted snapshot directories out of
review unless a change explicitly requires them.
