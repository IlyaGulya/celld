# Cloudflare OS compatibility sentinel

This example is a focused compatibility test for the runtime primitives Cloudflare OS uses in Code Mode and Gatekeepers.

It is intentionally smaller than Cloudflare OS itself. The goal is to make missing semantics reproducible in seconds once `celld` is built.

## Cases

### 1. Plain Dynamic Worker from Wrangler config

`/plain` loads a fresh Dynamic Worker and invokes its default entrypoint. The Loader is declared through `worker_loaders` in `wrangler.jsonc`, not a process-wide environment override.

This is the control case. If it fails, the Worker Loader itself is not usable for Cloudflare OS.

### 2. JSON vars

`/json-var` verifies that a non-string Wrangler `vars` value arrives in `env` as JSON rather than a stringified value. Cloudflare OS uses this for values such as the `ADMINS` array.

### 3. KV `preview_id`

`/kv-preview` writes and reads a KV binding declared with only `preview_id`, matching Wrangler local-development configs.

### 4. Service binding transport

`/service` passes a plain `ctx.exports` `ServiceStub` through a Dynamic Worker's `env` and calls it from the loaded isolate. This isolates basic cross-isolate service transport from per-instance props.

### 5. Props-bearing service capability

`/capability` follows Cloudflare's documented custom-binding pattern:

1. the loader Worker creates `ctx.exports.EchoTool({ props })`;
2. that RPC stub is passed to `env.LOADER.load({ env: { TOOL: stub } })`;
3. the Dynamic Worker calls `env.TOOL.echo()`.

Cloudflare OS uses this shape for scoped Gadget/Gatekeeper loopbacks.

### 6. Transient `RpcTarget` argument

`/transient` passes a request-scoped `RpcTarget` as an argument to a loaded Worker entrypoint. The loaded isolate calls the capability back in the originating isolate while preserving the originating request context. Inside one process this is a direct bridge; across fleet nodes the marker carries only the origin node identity plus an opaque capability id and the call is routed over celld's authenticated peer channel.

This is the primitive tracked by `denoland/celld#174` and required by Cloudflare OS Code Mode for capabilities such as `RestoreForgerImpl`; replacing it with a bearer-token HTTP endpoint would weaken the capability model.

### 7. `ctx.exports` Durable Object facet class

`/facet` creates a props-bearing `DurableObjectClass` using `ctx.exports.FacetTool({ props })` and passes it to `ctx.facets.get()`.

Cloudflare OS uses this shape when instantiating Gatekeeper facets.

### 8. `ctx.exports` Durable Object namespace surface

`/ctx-exports-do` reaches a migration-declared Durable Object through `ctx.exports.DirectTool.getByName()` and invokes an RPC method on the resulting stub.

Cloudflare OS uses this exact shape for `ctx.exports.AdminSettings.getByName("")` during `/api` startup. A self-exported Durable Object therefore has a dual surface: it is callable as a props-bearing `DurableObjectClass` for Facets and also exposes the normal namespace methods (`get`, `getByName`, `idFromName`, and related helpers).

### 9. Same-named Durable Object classes in co-hosted services

The sentinel also starts two service Workers that both export `UserAccount` and both call `getByName("shared-name")`. Their public class names intentionally collide, but their namespace identities are script-scoped. The calls must produce independent durable histories (`a:1`, `a:2` versus `b:110`, `b:120`).

This matches real Cloudflare OS deployments, where unrelated Gatekeepers commonly use generic internal class names such as `UserAccount`. A deployment graph must therefore route Durable Objects by script-scoped identity rather than treating the JavaScript class name as globally unique.

## Run

Build celld, ensure `esbuild` and `curl` are on `PATH`, then:

```sh
bash examples/cloudflare-os-compat/test.sh ./target/debug/celld
```

The script starts `celld dev` directly from the Wrangler config, runs every case, prints a separate PASS/FAIL result, and exits non-zero if any case fails.

### Two-node HA

The normal sentinel is intentionally single-process. To exercise the fleet seam against a dedicated S3-compatible prefix, run:

```sh
CELLD_HA_BUCKET=s3://my-test-bucket/cloudflare-os-ha \
CELLD_HA_ENDPOINT=http://127.0.0.1:9000 \
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  bash examples/cloudflare-os-compat/ha-test.sh ./target/debug/celld
```

The HA test starts two production-mode nodes, creates durable state on node A, invokes a returned transient `RpcTarget` through node B, then SIGKILLs A. One request to B must wait for ownership turnover and return the same acknowledged durable state without a client-side retry loop. Use only a disposable bucket prefix: the script deploys its fixture there.

### Three-node fleet

Ownership at fleet size is not visible with two nodes. This gate runs three on one bucket, spreads six cells over them by writing each first through a different node, and then asserts:

- every node serves every cell, including cells it does not own, so the call crosses to the owner (a two-hop path from the node that owns neither);
- each cell is owned exactly once across the fleet's own views, and more than one node holds cells;
- killing the node that holds the most cells leaves both survivors serving every cell, and the same identity rejoining leaves all three serving again.

```sh
CELLD_FLEET_BUCKET=s3://my-test-bucket/cloudflare-os-fleet \
CELLD_FLEET_ENDPOINT=http://127.0.0.1:9000 \
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  bash examples/cloudflare-os-compat/fleet-test.sh ./target/debug/celld
```

A cell's key is a digest of its identity, so the gate reads the count, exclusivity and spread from the fleet's own `/state` view rather than mapping names to owners. `CELLD_FLEET_CELLS` (default 6), `CELLD_FLEET_NODES` (default 3) and `CELLD_FLEET_TIMEOUT_S` (default 60) tune it. Use a dedicated disposable prefix.

### Object-store restore

To prove the fleet object store is the backup boundary rather than a node's local `CELLD_WATCH`, copy one dedicated source prefix into a different restore prefix and start from an empty local state directory:

```sh
CELLD_BACKUP_SOURCE=s3://my-test-bucket/source \
CELLD_BACKUP_RESTORE=s3://my-test-bucket/restore \
CELLD_BACKUP_ENDPOINT=http://127.0.0.1:9000 \
CELLD_MC=/path/to/mc \   # or ./examples/cloudflare-os-compat/mc-shim.py
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  bash examples/cloudflare-os-compat/restore-test.sh ./target/debug/celld
```

The script publishes a plain Durable Object fixture, waits for a bucket-durable write, SIGKILLs the source node, mirrors the complete S3 prefix with MinIO `mc`, and starts a restore node with a brand-new local state directory. The restored node must recover the acknowledged value from the copied prefix alone. Use only disposable prefixes.

`mc` itself is no longer published (`dl.min.io` answers 410 since the project was archived), so `mc-shim.py` in this directory implements the four subcommands the gate needs (`alias set`/`remove`, `mb`, `rm --recursive --force`, `mirror --overwrite`) against the same endpoint, copying server-side. Point `CELLD_MC` at it to run the gate without a MinIO installation.

### Mixed peer-protocol replacement

When a celld change bumps the authenticated peer protocol, exercise the fail-closed rolling replacement with an old and a new binary:

```sh
CELLD_UPGRADE_BUCKET=s3://my-test-bucket/cloudflare-os-upgrade \
CELLD_UPGRADE_ENDPOINT=http://127.0.0.1:9000 \
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  bash examples/cloudflare-os-compat/upgrade-test.sh \
    /path/to/old-celld ./target/debug/celld
```

The old binary publishes a plain Durable Object fixture and becomes its owner. Which refusal the new node gives depends on the bucket the old one left behind, and the gate asserts whichever the runtime chooses:

- the old runtime's bucket format needs migrating, so the new node refuses to *boot* outright while an old lease is live (`wake_format::ensure_stopped`) - this is what a pre-v0.5.0 node as the old binary produces, and it is what the workflow exercises first;
- the bucket is already at the running format, so the new node serves and the per-request peer protocol check fails closed with `PeerIncompatible` - what a stock v0.5.0 node as the old binary produces.

Both shapes then require the same proof: after the old node stops and its lease expires, the replacement recovers the latest bucket-acknowledged value, and the replaced slot rejoins on the new binary so both nodes read the same value. Use a dedicated disposable bucket prefix.

### Long-run soak with storage faults

The gates above answer "does a failover work" in seconds. The soak answers what only time answers: does an acknowledged write stay durable across repeated turnovers, do transient-capability bridges leak, does the bucket or a node's memory grow without bound, and do storage faults become lost writes.

```sh
CELLD_SOAK_BUCKET=s3://my-test-bucket/soak \
CELLD_SOAK_ENDPOINT=http://127.0.0.1:9000 \
CELLD_SOAK_DURATION_S=3600 \
CELLD_SOAK_KILL_EVERY_S=120 \
CELLD_SOAK_S3_FAULT_PERCENT=2 \
CELLD_SOAK_S3_FAULT_LATENCY_MS=25 \
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  bash examples/cloudflare-os-compat/soak-test.sh ./target/debug/celld
```

The script deploys the same fixture as the HA gate, starts two nodes, drives concurrent writers and readers through both, kills a node on a schedule and brings the same identity back, runs the store behind `s3-fault-proxy.py` when fault injection is on, and judges one PASS/FAIL line per bar:

| Bar | Meaning |
|---|---|
| no unexpected errors | a failed call may only land between a `kill` and the matching `rejoin` plus the settle period |
| no rollback | a read taken after a write was acknowledged never returns a lower value |
| no invented state | no read exceeds the highest value any writer acknowledged by the end of the run |
| acknowledged write survived | after the load stops, a fresh read returns exactly the last acknowledged value (RPO=0) |
| turnover exercised | at least one kill and one rejoin happened |
| bridges retired | the origin node's `rpc_bridge_handles` is 0 once the load stops |
| bridges bounded | it never exceeded `CELLD_SOAK_BRIDGE_MAX` during the load |
| bucket growth bounded | the prefix holds at most `CELLD_SOAK_BYTES_PER_WRITE_MAX` bytes per acknowledged write |
| node memory bounded | RSS growth after the first quarter stays under `CELLD_SOAK_RSS_GROWTH_MB` (the first minutes are warmup) |

Knobs: `CELLD_SOAK_NODES` (default 2; the fleet is killed round-robin and every node is sampled for bridge handles, so a leak on any node fails the run), `CELLD_SOAK_DURATION_S`, `_KILL_EVERY_S`, `_RESTART_AFTER_S`, `_SETTLE_S`, `_WRITERS`, `_READERS`, `_PACE_MS`, `_S3_FAULT_PERCENT`, `_S3_FAULT_LATENCY_MS`, `_S3_FAULT_SEED`, `_BRIDGE_MAX`, `_BYTES_PER_WRITE_MAX`, `_RSS_GROWTH_MB`, `_QUIESCE_S`. Set `CELLD_SOAK_KEEP_TMP=1` to keep the report, node logs and RSS trajectory instead of deleting the run directory. Use a dedicated disposable bucket prefix.

## TDD rule

Do not weaken these tests to make the suite green. In particular, do not replace either capability with an HTTP endpoint/token. The desired result is compatibility with the Cloudflare runtime model used by Cloudflare OS.
