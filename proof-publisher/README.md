# Fractal Proof Publisher

`proof-publisher` runs `fractal-proof-publisher`, the service that registers
your Fractal indexer and publishes `prove` inscriptions from your indexed state.
In this deployment repository it is a required component for users who want to
submit proofs and receive proof submission rewards.

The service holds signing material and can broadcast transactions. Configure it
manually, review every address and key, and start it only after the Fractal node
and Fractal indexer API are running.

## What It Does

- Publishes a `register` inscription when `register.indexer_id` is empty.
- Publishes `prove` inscriptions for eligible block heights.
- Reads state hashes from the local Fractal indexer API.
- Signs commit/reveal transactions with the configured publishing wallet.
- Broadcasts transactions through UniSat Open API in `unisat_open_api` mode, or
  through Fractald RPC in default mode.
- Stores local progress in SQLite under `data/`.

## Dependencies

- A running Fractald node with RPC reachable from Docker as `http://fractald:10332`
- A running Fractal indexer API reachable as `http://fractal-indexer:8000`
- A funded publishing wallet private key and its change address
- A reward address for indexer registration
- A UniSat Open API key when using `runtime.mode: "unisat_open_api"`
- Manual `signing.initial_utxos` when using default mode without Open API refill
- A UniSat Open API key when using default mode with
  `runtime.local_utxo_open_api_refill: true`

The default compose file expects Fractald and the Fractal indexer API to be
attached to the shared external Docker network `fractal-indexer-fip101-net`.

## Quick Configuration

From the repository root, run the top-level deployment first so `fractald` and
`fractal-indexer` are configured and started:

```bash
scripts/deploy.sh --snapshot=latest
```

Then create and review the proof publisher config:

```bash
cd proof-publisher
test -f config.json || cp config.example.json config.json
```

`scripts/deploy.sh` does not generate `proof-publisher/config.json`. Copy the RPC
credentials from `../fractald/conf/bitcoin.conf`; the normal state API address is
already present in the template as `http://fractal-indexer:8000`.

The example is a template and is not valid JSON until both instructional values
below are replaced:

- Replace `"start_height": REPLACE_START_HEIGHT` with a numeric chain height.
- Replace `"mode": "default" OR "unisat_open_api"` with exactly one JSON
  string, either `"mode": "default"` or `"mode": "unisat_open_api"`.

Common required values for both modes:

- `bitcoin_rpc.user`
- `bitcoin_rpc.password`
- `signing.private_key_wif` or `signing.private_key_hex`
- `signing.change_address`
- `register.reward_addr`
- `register.name`
- `scan.start_height`

For the recommended `unisat_open_api` mode, also set:

- `runtime.mode`: `unisat_open_api`
- `runtime.unisat_open_api_url`: normally `https://open-api.unisat.io`
- `runtime.unisat_open_api_key`

For default mode, set:

- `runtime.mode`: `default` or leave it empty
- `signing.initial_utxos`: at least one spendable UTXO controlled by the
  publishing private key, unless `runtime.local_utxo_open_api_refill` is enabled
- `runtime.local_utxo_open_api_refill`: optional; set to `true` to let the
  publisher refill its local UTXO ledger from UniSat Open API

Default mode broadcasts commit/reveal transactions through Fractald RPC, so the
Fractald RPC account must allow `sendrawtransaction`. If
`runtime.local_utxo_open_api_refill` is `false`, UniSat Open API credentials are
not required. If it is `true`, `runtime.unisat_open_api_url` and
`runtime.unisat_open_api_key` are required for UTXO refill only.

If the indexer is already registered, set `register.indexer_id` to the existing
value. If it is empty, the publisher creates a `register` submission before
publishing proofs.

Start the service:

```bash
jq empty config.json
bash ./scripts/init.sh
docker compose up -d
```

Do not start the service unless `jq empty config.json` succeeds and all required
placeholder values have been replaced.

## Required Config Values

### Fractald RPC

`bitcoin_rpc.user` and `bitcoin_rpc.password` come from
`fractald/conf/bitcoin.conf`:

```text
rpcuser=...
rpcpassword=...
```

When you use the top-level `scripts/deploy.sh`, it generates or reuses these
credentials in `fractald/conf/bitcoin.conf`. Copy them into
`proof-publisher/config.json` manually.

`bitcoin_rpc.url` should normally stay as:

```json
"url": "http://fractald:10332"
```

### Fractal Indexer API

`state_api.base_url` should normally stay as:

```json
"base_url": "http://fractal-indexer:8000"
```

With `provider: "query-fip101"`, the publisher reads state hashes from:

```text
GET /brc20/statehash?start={height}&end={height}
```

### UniSat Open API Key

`unisat_open_api` mode uses UniSat Open API for UTXO lookup and transaction
broadcast. Default mode also needs UniSat Open API credentials when
`runtime.local_utxo_open_api_refill` is `true`, but still broadcasts
commit/reveal transactions through Fractald RPC.

To get the key:

1. Open [UniSat Developer Center](https://developer.unisat.io/).
2. Register or log in.
3. Find the `Fractal Mainnet` page.
4. Copy the `API-Key`.
5. Put it in `runtime.unisat_open_api_key`.

Reference documentation:
[docs.unisat.io/developer-support/open-api-documentation](https://docs.unisat.io/developer-support/open-api-documentation)

You can paste the raw API key. The publisher normalizes it to Bearer token
format internally.

### Default Mode UTXO Sources

Default mode can use either manually configured UTXOs or automatic local-ledger
refill from UniSat Open API.

For a fully local default-mode setup, keep `runtime.local_utxo_open_api_refill`
set to `false` and fill `signing.initial_utxos` before startup with one or more
currently unspent outputs from `signing.change_address` or another address
controlled by the publishing private key:

```json
"initial_utxos": [
  {
    "txid": "REPLACE_TXID",
    "vout": 0,
    "amount_sat": 100000,
    "address": "REPLACE_UTXO_ADDRESS",
    "script_pub_key": "REPLACE_SCRIPT_PUB_KEY",
    "address_type": "p2wpkh"
  }
]
```

`script_pub_key` must match the exact output script for that UTXO, and
`address_type` must match the funded address type, such as `p2wpkh`, `p2tr`,
`p2sh-p2wpkh`, or `p2pkh`. Do not list UTXOs that are already spent, reserved by
another publisher instance, or not controlled by the configured private key.

For default mode with automatic refill, set:

```json
"runtime": {
  "mode": "default",
  "unisat_open_api_url": "https://open-api.unisat.io",
  "unisat_open_api_key": "REPLACE_UNISAT_OPEN_API_KEY",
  "local_utxo_open_api_refill": true
}
```

With `runtime.local_utxo_open_api_refill: true`, the publisher can refill its
local UTXO ledger from UniSat Open API for `signing.change_address`. This is
useful when the local ledger has no usable UTXO or has insufficient funds. The
service keeps reserved UTXOs intact, restores non-reserved spendable entries from
Open API, and checks suspect UTXOs with Fractald RPC `gettxout` before deciding
whether they are available again or invalid.

### Publishing Private Key

`signing.private_key_wif` or `signing.private_key_hex` is the private key used
to sign `register` and `prove` commit/reveal transactions.

Recommended setup:

1. Create a dedicated Fractal/Bitcoin-compatible wallet for publishing.
2. Export the private key for that wallet address in WIF format.
3. Set it as `signing.private_key_wif`.
4. Send a small amount of FB to the wallet address for publishing costs and
   transaction fees.

Do not use a main treasury wallet or a wallet holding large funds. This service
is a hot-wallet process.

### Change Address

`signing.change_address` is the address controlled by the publishing private
key. Commit transaction change and reveal outputs are sent to this address.

Use the address that matches `signing.private_key_wif` or
`signing.private_key_hex`. If the private key cannot spend funds from
`signing.change_address`, transaction signing or later spending will fail.

Fund this address with several small UTXOs instead of a single large output. At
least 3 spendable UTXOs is recommended so the publisher can submit proofs
smoothly while previous transactions are still confirming.

### Reward Address

`register.reward_addr` is the reward address announced when the publisher
registers your indexer.

It can be the same as `signing.change_address`, but using a separate receiving
or cold-wallet address is safer for long-term funds. Set
`register.reward_addr_type` to match the address type, for example `p2wpkh`.

### Indexer Name and ID

- `register.name`: public name for your indexer registration.
- `register.indexer_id`: existing on-chain indexer ID.

Leave `register.indexer_id` empty for a new registration. After registration is
confirmed, the publisher stores the indexer ID in its local SQLite database. If
you are moving an existing registered indexer to this deployment, set the known
ID before starting.

### Scan Start Height

Set `scan.start_height` to the latest Fractal chain height when you start
`proof-publisher`.

The publisher scans from this height to find blocks that need proof submission.
Using the current height avoids replaying old ranges and keeps the first run
focused on new proof opportunities. You can get the current height from the
Fractal indexer API after the indexer is synced:

```bash
curl -s http://localhost:8000/brc20/bestheight
```

Use the returned height as `scan.start_height` before starting the service.

### Fee Rate Selection

The publisher selects a fee rate from `fee_api.strategy` and then clamps it with
`fee_api.min_fee_rate_sat_vb` and `fee_api.max_fee_rate_sat_vb`.

Supported `fee_api.strategy` values:

- `fastest`: use the fastest recommended fee.
- `hour` or `hourfee`: use the one-hour recommended fee.
- `minimum` or `min`: use the minimum recommended fee.
- `half_hour`, `halfhour`, `half-hour`, or an empty value: use the half-hour
  recommended fee.
- Any unknown value also falls back to the half-hour recommended fee.

After the strategy selects a candidate fee rate:

1. If it is lower than `fee_api.min_fee_rate_sat_vb`, the minimum value is used.
2. If `fee_api.max_fee_rate_sat_vb` is greater than `0` and the candidate is
   higher than that maximum, the maximum value is used.
3. If the final value is still `0` or negative, the publisher uses `1 sat/vB`.

For a fixed-fee deployment, set `fee_api.min_fee_rate_sat_vb` and
`fee_api.max_fee_rate_sat_vb` to the same positive value. The example config uses
`fee_api.strategy: "halfhour"`, `fee_api.min_fee_rate_sat_vb: 1`, and
`fee_api.max_fee_rate_sat_vb: 0`, so the selected recommended fee is floored at
`1 sat/vB` without an upper cap.

## Runtime Mode

### Recommended: `unisat_open_api`

This deployment template is designed for:

```json
"runtime": {
  "mode": "unisat_open_api",
  "unisat_open_api_url": "https://open-api.unisat.io",
  "unisat_open_api_key": "REPLACE_UNISAT_OPEN_API_KEY"
}
```

In this mode:

- `runtime.unisat_open_api_url` and `runtime.unisat_open_api_key` are required.
- `signing.initial_utxos` can remain empty.
- UTXOs are fetched from UniSat Open API for `signing.change_address`.
- Commit and reveal transactions are pushed through UniSat Open API.
- Fractald RPC is still required for block reads and scanning.

### Advanced: `default`

The upstream publisher treats only `unisat_open_api` as a special runtime mode.
An empty value, `default`, or any other string uses default mode.

In default mode:

- `runtime.unisat_open_api_key` is not required when
  `runtime.local_utxo_open_api_refill` is `false`.
- `signing.initial_utxos` must contain at least one spendable UTXO when
  `runtime.local_utxo_open_api_refill` is `false`.
- `runtime.local_utxo_open_api_refill: true` allows the publisher to refill its
  local UTXO ledger from UniSat Open API, and requires
  `runtime.unisat_open_api_url` plus `runtime.unisat_open_api_key`.
- Commit and reveal transactions are broadcast with Fractald RPC
  `sendrawtransaction`.
- Commit and reveal confirmations are detected by scanning blocks through
  Fractald RPC.

Each `signing.initial_utxos` item must describe an unspent output controlled by
the signing key:

```json
{
  "txid": "REPLACE_TXID",
  "vout": 0,
  "amount_sat": 100000,
  "address": "REPLACE_UTXO_ADDRESS",
  "script_pub_key": "REPLACE_SCRIPT_PUB_KEY",
  "address_type": "p2wpkh"
}
```

`script_pub_key` must be the output script for that exact UTXO, and
`address_type` must match the address type used by the output, such as
`p2wpkh`, `p2tr`, `p2sh-p2wpkh`, or `p2pkh`. Do not reuse UTXOs that are spent
or reserved by another process.

## Operational Flags

- `runtime.dry_run=true`: exits without doing publishing work.
- `runtime.disable_broadcast=true`: builds and records transactions but does
  not broadcast them.
- `runtime.health_addr`: starts the local health/status HTTP server, default
  `:8080`.

## Verify

```bash
docker compose ps
docker compose logs --tail=100 -f proof-publisher
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/status
```

The health/API port binds to `127.0.0.1` by default. Set `BIND_HOST=0.0.0.0`
only when external access is required and the host firewall/security group is
configured.

## Security Notes

- Do not commit `config.json`, private keys, API keys, or the `data/` directory.
- Use a dedicated hot wallet and fund it with only the amount needed for
  publishing and fees.
- Test with a small balance before running long-term.
- Back up the publishing wallet key securely.
- Do not expose Fractald RPC, databases, caches, or proof publisher status APIs
  to the public internet unless your firewall and access controls are already
  configured.
