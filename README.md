# Fractal Indexer Deploy

This repository helps you run a Fractal indexer and submit FIP101 proofs from
your own indexed data.

The main deployment path is:

- `fractald/`: runs the Fractal node.
- `fractal-indexer/`: indexes BRC20 data and exposes the state/query API.
- `proof-publisher/`: registers your indexer and publishes `prove`
  inscriptions, which submit FIP101 proofs for reward participation.

The top-level deployment script prepares the node and indexer stack. The proof
publisher must be reviewed and started manually because it holds a signing key
and can broadcast transactions.

Upstream project repositories:

- `fractald`: [github.com/fractal-bitcoin/fractald-release](https://github.com/fractal-bitcoin/fractald-release)
- `fractal-indexer`: [github.com/fractal-bitcoin/fractal-indexer](https://github.com/fractal-bitcoin/fractal-indexer)
- `fractal-proof-publisher`: [github.com/fractal-bitcoin/fractal-proof-publisher](https://github.com/fractal-bitcoin/fractal-proof-publisher)

## Service Endpoints

- Fractal indexer API: `http://localhost:8000`
- Proof publisher health: `http://localhost:8080/healthz`
- Proof publisher status: `http://localhost:8080/status`

`fractald` RPC and ZMQ ports are internal-only by default and are reachable by
containers on the shared Docker network as `fractald:10332`, `fractald:10330`,
and `fractald:10331`.

## Prerequisites

`scripts/deploy.sh` runs `scripts/install-deps.sh` by default and attempts to
install the required deployment tools automatically.

The deployment scripts support `apt-get`, `dnf`, and `yum` based systems. For
manual installation, use these official documents:

- Docker Engine with the Docker Compose plugin: [docs.docker.com/engine/install](https://docs.docker.com/engine/install/)
- `jq`: [jqlang.org/download](https://jqlang.org/download/)
- `kopia`, required for snapshot restore: [kopia.io/docs/installation](https://kopia.io/docs/installation/)
- `rsync`

`scripts/mount-kopia-snapshot.sh` also requires FUSE. The script checks for
FUSE and prints manual installation instructions when it is missing.

## Resource Requirements

- Single-host snapshot deployment on the same disk: disk `800 GB+`, minimum memory `64 GB`
- `fractald`: disk `400 GB+`, minimum memory `8 GB`, recommended memory `16 GB`
- `fractal-indexer`: disk `400 GB+`, minimum memory `48 GB`, recommended memory `96 GB`

## Run Quickly with an AI Agent

You can use an AI agent to deploy this stack on your server. Ask the agent to:

```text
Read https://github.com/fractal-bitcoin/fractal-indexer-deploy, install the
required dependencies, deploy the Fractal indexer stack with
scripts/deploy.sh --snapshot=latest, then help me configure proof-publisher.
```

## Quick Start

### 1. Deploy Fractald and Fractal Indexer

Deploy `fractald` and `fractal-indexer` from the latest snapshot:

```bash
git clone https://github.com/fractal-bitcoin/fractal-indexer-deploy
cd fractal-indexer-deploy
scripts/deploy.sh --snapshot=latest
```

The deploy script creates or updates local configs, including Fractald RPC
credentials and the Fractal indexer API address used by `proof-publisher`.
After the indexer stack is running, configure the proof publisher manually.

To redeploy from a clean state, stop services and remove runtime data first:

```bash
scripts/cleanup.sh --data
```

To download snapshot data only and skip service initialization/startup:

```bash
scripts/deploy.sh --snapshot=latest --download-only
```

### 2. Deploy Proof Publisher

`proof-publisher` is the component that submits your on-chain registration and
proof messages. It needs a funded signing wallet, a reward address, and either a
UniSat Open API key for `unisat_open_api` mode or explicit spendable UTXO details
for default mode.

Open the generated config:

```bash
cd proof-publisher
cp config.example.json config.json  # only if config.json was not generated
```

Review and set these common fields in `config.json`:

- `bitcoin_rpc.user` and `bitcoin_rpc.password`: from `fractald/conf/bitcoin.conf`
- `state_api.base_url`: normally `http://fractal-indexer:8000`
- `signing.private_key_wif`: private key for a dedicated funded publishing wallet
- `signing.change_address`: address controlled by the signing private key
- `register.reward_addr`: address that receives indexer rewards
- `register.name`: your indexer name
- `scan.start_height`: latest chain height when you start proof-publisher

For the recommended `unisat_open_api` mode, also set:

- `runtime.mode`: `unisat_open_api`
- `runtime.unisat_open_api_url`: normally `https://open-api.unisat.io`
- `runtime.unisat_open_api_key`: API key from UniSat Developer Center

For default mode, set:

- `runtime.mode`: `default` or leave it empty
- `signing.initial_utxos`: at least one spendable UTXO controlled by the
  publishing private key

Default mode does not require `runtime.unisat_open_api_key`. It uses Fractald
RPC `sendrawtransaction` to broadcast commit/reveal transactions, so make sure
the configured Fractald RPC account can broadcast transactions.

Fund `signing.change_address` with several small UTXOs. At least 3 UTXOs is
recommended so proof submissions can continue smoothly. In default mode, list
one or more of those unspent outputs in `signing.initial_utxos`, including
`txid`, `vout`, `amount_sat`, `address`, `script_pub_key`, and `address_type`.

When using `unisat_open_api` mode, get the UniSat Open API key from
[UniSat Developer Center](https://developer.unisat.io/). Register or log in,
open the `Fractal Mainnet` page, and copy the `API-Key`. UniSat's reference
documentation is at
[docs.unisat.io/developer-support/open-api-documentation](https://docs.unisat.io/developer-support/open-api-documentation).

Then start the publisher:

```bash
bash ./scripts/init.sh
docker compose up -d
```

For detailed configuration notes, including private key handling, address
meaning, and non-UniSat `default` mode, see
[proof-publisher/README.md](proof-publisher/README.md).

## Manual Service Deployment

For manual deployment of individual services, see the README in each service
directory:

- `fractald`: [fractald/README.md](fractald/README.md)
- `fractal-indexer`: [fractal-indexer/README.md](fractal-indexer/README.md)
- `proof-publisher`: [proof-publisher/README.md](proof-publisher/README.md)

## Network and Port Security

The Docker Compose stacks use a shared external Docker network named
`fractal-indexer-fip101-net`.

`scripts/deploy.sh` creates this network before starting services. For manual
service deployment, create it first:

```bash
docker network create fractal-indexer-fip101-net
```

Internal services do not publish host ports:

- `fractald` RPC and ZMQ: `10332`, `10330`, `10331`
- ClickHouse: `9000`
- Pika: `9221`

Public endpoints bind to `127.0.0.1` by default:

- Fractal indexer API: `8000`
- Proof publisher health/API: `8080`

Set `BIND_HOST=0.0.0.0` only when these APIs must be reachable from outside the
host and the network perimeter is already protected.

## Available Snapshot Heights

The latest snapshot height is `2229982`. Available snapshot heights:

- `1827409`
- `1881585`
- `2229982` (latest)

Deploy a specific snapshot with `scripts/deploy.sh --snapshot=2229982`, or use
`scripts/deploy.sh --snapshot=latest` to select the highest height with all three
required datasets passing the snapshot completeness checks.

## List Uploaded Snapshot Heights

```bash
scripts/list-kopia-snapshot-heights.sh
scripts/list-kopia-snapshot-heights.sh --all-schemas
```

Prints unique heights in ascending numeric order, one per line. By default,
records must match the current `SNAPSHOT_SCHEMA_VERSION`; `--all-schemas`
includes all schemas and records without a schema tag. This inventory includes
incomplete/checkpoint records and heights with missing datasets, so a listed
height is not necessarily ready to restore. Connection diagnostics go to stderr.

## Restore One Snapshot Dataset

Use `scripts/restore-kopia-snapshot.sh` to restore one Kopia snapshot dataset by
numeric height, dataset name, and target directory:

```bash
scripts/restore-kopia-snapshot.sh \
  --height=2229982 \
  --dataset=fractald-blocks \
  --target=fractald/data/blocks
```

By default, the restore script deletes files in the target directory that are not
present in the snapshot. Add `--no-delete-extra` to keep extra files.

Common datasets:

- `fractald-blocks` to `fractald/data/blocks`
- `fractald-chainstate` to `fractald/data/chainstate`
- `fractal-indexer-data` to `fractal-indexer/data`

## Deploy Without Snapshots

You can run the deploy script without `--snapshot`:

```bash
scripts/deploy.sh
```

Without snapshots, `fractald` must sync from genesis and `fractal-indexer` must
build its data from the beginning. This can take a long time.

Before running without snapshots, consider removing the `fractald` `prune`
configuration from `fractald/conf/bitcoin.conf` or
`fractald/conf/bitcoin.conf.example`. Running `fractal-indexer` against a pruned
node may cause indexing failures.

A full node plus full index data requires more than `3 TB` of disk space. For a
full index rebuild from genesis, `128 GB+` memory is recommended.

When running without `--snapshot`, the script prints these requirements and asks
for confirmation before continuing. Add `--yes` only when you are intentionally
running in a non-interactive environment.

## Cleanup

Use `scripts/cleanup.sh` to stop services or remove generated runtime state:

```bash
scripts/cleanup.sh --stop
scripts/cleanup.sh --data
scripts/cleanup.sh --all
```

- `--stop` stops all services without deleting data.
- `--data` stops all services and deletes runtime `data/` directories. You must
  type `data` to confirm.
- `--all` stops all services and deletes runtime data, logs, generated configs,
  and the local Kopia cache. You must type `all` to confirm.

## Validation

Use these commands after startup:

```bash
docker compose ps
docker compose logs --tail=100 -f
```

Check:

- `http://localhost:8000/brc20/bestheight` for the Fractal indexer API
- `http://localhost:8080/healthz` for the proof publisher
- `http://localhost:8080/status` for proof publisher status

## Changelog

### 20261026

1. Updated the latest snapshot height to `2229982` and documented available heights `1827409`, `1881585`, and `2229982`.
2. Unified snapshot completeness checks for restore and mount, rejecting empty roots, incomplete/checkpoint records, and snapshots with failed file reads.
3. Updated `--snapshot=latest` to select and retain all three verified dataset roots in one query.
4. Made snapshot query and JSON parsing failures explicit instead of reporting them as missing snapshots.
5. Added `scripts/list-kopia-snapshot-heights.sh` to list uploaded heights, with `--all-schemas` support, and fixed Kopia connection argument handling on Bash 3.2.

### 20260702

1. Upgraded `fractalbitcoin/fractal-proof-publisher` to `v0.1.3`, including improved proof resubmission logic after block reorganizations and UTXO selection from largest to smallest.
2. Updated Proof Publisher fee defaults to use the Fractal mempool fee API with `halfhour` strategy and no maximum fee cap.
3. Documented Proof Publisher fee-rate strategy selection, min/max clamping, and `1 sat/vB` fallback behavior.

### 20260623
1. Updated the `fractal-indexer` `db.yaml` configuration, adjusting `read_timeout` and `write_timeout` to 60 seconds.

### 20260612

1. Documented Proof Publisher `default` mode alongside `unisat_open_api` mode.
2. Added default-mode `signing.initial_utxos` guidance for manual Fractald RPC broadcasting.
3. Upgraded `fractalbitcoin/fractal-proof-publisher` to `v0.1.2`.

### 20260606

1. Added one-command snapshot restore and deployment with `scripts/deploy.sh --snapshot=latest`.
2. Updated the latest snapshot height to `1827409`.
3. Improved network security by binding API endpoints to local access by default.

