# Cloudflare OS compatibility sentinel

This example is a focused compatibility test for the runtime primitives Cloudflare OS uses in Code Mode and Gatekeepers.

It is intentionally smaller than Cloudflare OS itself. The goal is to make missing semantics reproducible in seconds once `celld` is built.

## Cases

### 1. Plain Dynamic Worker

`/plain` loads a fresh Dynamic Worker and invokes its default entrypoint.

This is the control case. If it fails, the Worker Loader itself is not usable for Cloudflare OS.

### 2. Service binding transport

`/service` passes a plain `ctx.exports` `ServiceStub` through a Dynamic Worker's `env` and calls it from the loaded isolate. This isolates basic cross-isolate service transport from per-instance props.

### 3. Props-bearing service capability

`/capability` follows Cloudflare's documented custom-binding pattern:

1. the loader Worker creates `ctx.exports.EchoTool({ props })`;
2. that RPC stub is passed to `env.LOADER.load({ env: { TOOL: stub } })`;
3. the Dynamic Worker calls `env.TOOL.echo()`.

Cloudflare OS uses this shape for scoped Gadget/Gatekeeper loopbacks.

### 4. Transient `RpcTarget` argument

`/transient` passes a request-scoped `RpcTarget` as an argument to a loaded Worker entrypoint. The loaded isolate calls the capability back in the originating isolate through the process-local RPC bridge while preserving the originating request context.

This is the primitive tracked by `denoland/celld#174` and required by Cloudflare OS Code Mode for capabilities such as `RestoreForgerImpl`; replacing it with a bearer-token HTTP endpoint would weaken the capability model.

### 5. `ctx.exports` Durable Object facet class

`/facet` creates a props-bearing `DurableObjectClass` using `ctx.exports.FacetTool({ props })` and passes it to `ctx.facets.get()`.

Cloudflare OS uses this shape when instantiating Gatekeeper facets.

## Run

Build celld, ensure `esbuild` and `curl` are on `PATH`, then:

```sh
bash examples/cloudflare-os-compat/test.sh ./target/debug/celld
```

The script starts `celld dev` with `CELLD_WORKER_LOADER=LOADER`, runs every case, prints a separate PASS/FAIL result, and exits non-zero if any case fails.

## TDD rule

Do not weaken these tests to make the suite green. In particular, do not replace either capability with an HTTP endpoint/token. The desired result is compatibility with the Cloudflare runtime model used by Cloudflare OS.
