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

### Object-store restore

To prove the fleet object store is the backup boundary rather than a node's local `CELLD_WATCH`, copy one dedicated source prefix into a different restore prefix and start from an empty local state directory:

```sh
CELLD_BACKUP_SOURCE=s3://my-test-bucket/source \
CELLD_BACKUP_RESTORE=s3://my-test-bucket/restore \
CELLD_BACKUP_ENDPOINT=http://127.0.0.1:9000 \
CELLD_MC=/path/to/mc \
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  bash examples/cloudflare-os-compat/restore-test.sh ./target/debug/celld
```

The script publishes a plain Durable Object fixture, waits for a bucket-durable write, SIGKILLs the source node, mirrors the complete S3 prefix with MinIO `mc`, and starts a restore node with a brand-new local state directory. The restored node must recover the acknowledged value from the copied prefix alone. Use only disposable prefixes.

### Mixed peer-protocol replacement

When a celld change bumps the authenticated peer protocol, exercise the fail-closed rolling replacement with an old and a new binary:

```sh
CELLD_UPGRADE_BUCKET=s3://my-test-bucket/cloudflare-os-upgrade \
CELLD_UPGRADE_ENDPOINT=http://127.0.0.1:9000 \
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  bash examples/cloudflare-os-compat/upgrade-test.sh \
    /path/to/old-celld ./target/debug/celld
```

The old binary publishes a plain Durable Object fixture and becomes its owner. The new node must explicitly refuse the incompatible owner rather than attempt peer RPC, then recover the latest bucket-acknowledged value after the old owner's lease expires. Finally, the replaced slot rejoins on the new binary and both nodes must read the same value. Use a dedicated disposable bucket prefix.

## TDD rule

Do not weaken these tests to make the suite green. In particular, do not replace either capability with an HTTP endpoint/token. The desired result is compatibility with the Cloudflare runtime model used by Cloudflare OS.
