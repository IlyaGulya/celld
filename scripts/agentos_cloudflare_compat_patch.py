#!/usr/bin/env python3
"""Apply the minimal AgentOS Cloudflare-OS compatibility patch.

Kept as an explicit source transform while iterating TDD so each semantic change
is reviewable independently. Once the compatibility suite is green, squash the
result into normal source edits before proposing upstream.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one patch site, found {count}")
    path.write_text(text.replace(old, new, 1))


harness = ROOT / "crates/celld/js/harness.js"

old_loader = '''  // getCode is deferred into a microtask so a throw (or async getCode)
  // surfaces as a rejection when the worker is first used, not at get()/load().
  const loadFrom = (getCode) =>
    Promise.resolve().then(getCode)
      .then((c) => {
        const { config, wasm } = encodeModules(c);
        return __loader_load(JSON.stringify(config), wasm);
      });
'''

new_loader = '''  // Turn durable loopback ServiceStubs into data that a fresh isolate can
  // reconstruct as an ordinary cross-script service binding. JSON.stringify
  // would otherwise silently omit the function-valued stub from `env`.
  //
  // This intentionally handles only ctx.exports ServiceStubs here. Transient
  // RpcStubs/RpcTargets require a real cross-isolate handle bridge and remain
  // covered by a separate failing compatibility test.
  const encodeLoaderEnv = (env) => {
    if (env === undefined) return undefined;
    const out = {};
    for (const [name, value] of Object.entries(env)) {
      const svc = __svcMeta.get(value);
      if (svc === undefined) {
        out[name] = value;
        continue;
      }
      const marker = {
        "__celld$loaderSvc": svc.name,
        s: __cell.script,
      };
      if (svc.props !== undefined) marker.p = svc.props;
      out[name] = marker;
    }
    return out;
  };

  // getCode is deferred into a microtask so a throw (or async getCode)
  // surfaces as a rejection when the worker is first used, not at get()/load().
  const loadFrom = (getCode) =>
    Promise.resolve().then(getCode)
      .then((c) => {
        const { config, wasm } = encodeModules(c);
        if (config && typeof config === "object" && config.env !== undefined)
          config.env = encodeLoaderEnv(config.env);
        return __loader_load(JSON.stringify(config), wasm);
      });
'''
replace_once(harness, old_loader, new_loader)

# A cross-script WorkerEntrypoint call already has a structured-clone payload.
# Reuse it for props rather than widening the Rust/peer protocol. The outer
# envelope cannot collide with ordinary RPC args because ordinary method calls
# always arrive as an Array.
old_session = '''const __entrypointSession = (name, local, script, makeInst) => ({
  get: (path) => local
    ? (async () => __rpcDes(
        await __entrypointOp(name, path, null, true, makeInst)))()
    : Promise.reject(new Error(
        "Awaitable properties on cross-script service bindings " +
        "are not supported yet.")),
  call: (path, args) => (async () => {
    const argsSc = __rpcOut(args, local);
    if (local)
      return __rpcDes(await __entrypointOp(
        name, path, argsSc, true, makeInst));
    if (path.length !== 1)
      throw new Error(
        "Pipelined property paths on cross-script service " +
        "bindings are not supported yet.");
    return __rpcDes(
      await __svc_rpc(script, name, path[0], argsSc));
  })(),
});
'''
new_session = '''const __entrypointSession = (
  name, local, script, makeInst, remoteProps,
) => ({
  get: (path) => local
    ? (async () => __rpcDes(
        await __entrypointOp(name, path, null, true, makeInst)))()
    : Promise.reject(new Error(
        "Awaitable properties on cross-script service bindings " +
        "are not supported yet.")),
  call: (path, args) => (async () => {
    const wireArgs = !local && remoteProps !== undefined
      ? { "__celld$entrypointCall": true, p: remoteProps, a: args }
      : args;
    const argsSc = __rpcOut(wireArgs, local);
    if (local)
      return __rpcDes(await __entrypointOp(
        name, path, argsSc, true, makeInst));
    if (path.length !== 1)
      throw new Error(
        "Pipelined property paths on cross-script service " +
        "bindings are not supported yet.");
    return __rpcDes(
      await __svc_rpc(script, name, path[0], argsSc));
  })(),
});
'''
replace_once(harness, old_session, new_session)

# On the receiving isolate, unwrap the private call envelope and construct the
# WorkerEntrypoint with the transmitted props. The instance is scoped to this
# RPC operation; no props value can leak into another ServiceStub/session.
old_entrypoint_op = '''const __entrypointOp = (name, path, argsSc, local, makeInst) => {
  const id = __nextCtxId++;
  return __ctxRun(id, () => (async () => {
  const decoded = argsSc === null ? null : __rpcDesArgs(argsSc);
  let drain = null;
'''
new_entrypoint_op = '''const __entrypointOp = (name, path, argsSc, local, makeInst) => {
  const id = __nextCtxId++;
  return __ctxRun(id, () => (async () => {
  const decoded = argsSc === null ? null : __rpcDesArgs(argsSc);
  let scopedInst;
  if (makeInst === undefined && decoded !== null &&
      decoded.args !== null && !Array.isArray(decoded.args) &&
      decoded.args["__celld$entrypointCall"] === true &&
      Array.isArray(decoded.args.a)) {
    const props = decoded.args.p;
    decoded.args = decoded.args.a;
    makeInst = () => {
      if (scopedInst !== undefined) return scopedInst;
      const cls = __cell.entrypoints[name];
      if (typeof cls !== "function")
        throw new TypeError(
          "The entrypoint " + name + " cannot carry props.");
      const ctx = __beginEvent(props);
      try {
        scopedInst = new cls(ctx, __cell.env);
      } finally {
        __endEvent();
      }
      return scopedInst;
    };
  }
  let drain = null;
'''
replace_once(harness, old_entrypoint_op, new_entrypoint_op)

# Install a recursive reviver because env may contain ordinary nested data.
# Nested capabilities are deliberately left for the generic handle bridge.
anchor = '''globalThis.__makeServiceBinding = (script, entrypoint = null) => {\n'''
reviver = '''globalThis.__reviveLoaderEnv = (env) => {
  const seen = new Map();
  const revive = (value) => {
    if (value === null || typeof value !== "object") return value;
    const cached = seen.get(value);
    if (cached !== undefined) return cached;
    const entrypoint = value["__celld$loaderSvc"];
    if (entrypoint !== undefined) {
      return globalThis.__makeServiceBinding(
        value.s, entrypoint, revive(value.p));
    }
    const out = Array.isArray(value) ? [] : {};
    seen.set(value, out);
    for (const [key, child] of Object.entries(value)) out[key] = revive(child);
    return out;
  };
  return revive(env);
};

globalThis.__makeServiceBinding = (
  script, entrypoint = null, props = undefined,
) => {
'''
replace_once(harness, anchor, reviver)

old_binding_session = '''  const session =
    __entrypointSession(entrypoint, script === __cell.script, script);
'''
new_binding_session = '''  const session =
    __entrypointSession(
      entrypoint, script === __cell.script, script, undefined, props);
'''
replace_once(harness, old_binding_session, new_binding_session)

# Keep this replacement deliberately tiny: upstream formats the Rust string
# with an escaped physical newline, which is easy to mismatch in a multiline
# Python literal. The JS fragment itself is unique in bootstrap.rs.
bootstrap = ROOT / "crates/celld/js/bootstrap.rs"
replace_once(
    bootstrap,
    'Object.assign(e, {});',
    'Object.assign(e, __reviveLoaderEnv({}));',
)

print(
    "Applied AgentOS Cloudflare OS compatibility patch: "
    "service env bridge + cross-isolate entrypoint props"
)
