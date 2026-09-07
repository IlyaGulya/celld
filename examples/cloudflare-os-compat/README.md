# Cloudflare OS compatibility sentinel

This example is a focused compatibility test for the runtime primitives Cloudflare OS uses in Code Mode and Gatekeepers.

It is intentionally smaller than Cloudflare OS itself. The goal is to make missing semantics reproducible in seconds once `celld` is built.

## Cases

### 1. Plain Dynamic Worker

`/plain` loads a fresh Dynamic Worker and invokes its default entrypoint.

This is the control case. If it fails, the Worker Loader itself is not usable for Cloudflare OS.

### 2. Cross-isolate capability binding

`/capability` follows Cloudflare's documented custom-binding pattern:

1. the loader Worker creates `ctx.exports.EchoTool({ props })`;
2. that RPC stub is passed to `env.LOADER.load({ env: { TOOL: stub } })`;
3. the Dynamic Worker calls `env.TOOL.echo()`.

This is the primitive tracked by `denoland/celld#174` and required by Cloudflare OS Code Mode to call scoped tools without replacing capabilities with broad bearer-token HTTP APIs.

### 3. `ctx.exports` Durable Object facet class

`/facet` creates a props-bearing `DurableObjectClass` using `ctx.exports.FacetTool({ props })` and passes it to `ctx.facets.get()`.

Cloudflare OS uses this shape when instantiating Gatekeeper facets. celld v0.4.1 documents facet classes obtained from `ctx.exports` as unavailable.

## Run

Build celld, ensure `esbuild` and `curl` are on `PATH`, then:

```sh
bash examples/cloudflare-os-compat/test.sh ./target/debug/celld
```

The script starts `celld dev` with `CELLD_WORKER_LOADER=LOADER`, runs every case, prints a separate PASS/FAIL result, and exits non-zero if any case fails.

## TDD rule

Do not weaken these tests to make the suite green. In particular, do not replace either capability with an HTTP endpoint/token. The desired result is compatibility with the Cloudflare runtime model used by Cloudflare OS.
