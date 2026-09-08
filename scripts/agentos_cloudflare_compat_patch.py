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

# Same-script Durable Object classes from ctx.exports. Reuse the existing
# loader-backed facet runtime by registering the current WorkerConfig once per
# isolate, rather than creating a second storage/fencing implementation.
js_rs = ROOT / "crates/celld/js.rs"
replace_once(
    js_rs,
    '''#[derive(Clone, Copy, Eq, PartialEq)]\nstruct LoaderOwner(u64);\n\nimpl LoaderOwner {''',
    '''#[derive(Clone, Copy, Eq, PartialEq)]\nstruct LoaderOwner(u64);\n\n#[derive(Clone, Copy)]\nstruct SelfLoaderId(u64);\n\nimpl LoaderOwner {''',
)
replace_once(
    js_rs,
    '''        "__loader_load" => op_loader_load,\n        "__loader_fetch" => op_loader_fetch,''',
    '''        "__loader_self" => op_loader_self,\n        "__loader_load" => op_loader_load,\n        "__loader_fetch" => op_loader_fetch,''',
)
loader_self_anchor = '''/// `__loader_load(codeJson)` -> stub id. Builds a WorkerConfig from the\n'''
loader_self_impl = '''/// `__loader_self()` -> stub id. Registers this deployment's own WorkerConfig
/// as a loader-backed runtime once per isolate. This lets ctx.exports expose
/// same-script DurableObjectClass values while reusing the existing facet
/// storage/fencing path instead of creating a second facet runtime.
fn op_loader_self(
    scope: &mut v8::PinScope,
    _args: v8::FunctionCallbackArguments,
    mut rv: v8::ReturnValue<v8::Value>,
) {
    if let Some(id) = scope.get_slot::<SelfLoaderId>() {
        rv.set(v8::Number::new(scope, id.0 as f64).into());
        return;
    }

    let owner = *scope
        .get_slot::<LoaderOwner>()
        .expect("Worker isolate has a Loader owner");
    let config = scope
        .get_slot::<Arc<BundleFs>>()
        .expect("Worker isolate has a bundle config")
        .config
        .clone();
    let max = crate::env_vars::positive_or("CELLD_MAX_LOADED_WORKERS", 256)
        .expect("validated CELLD_MAX_LOADED_WORKERS");
    if loader_registry().lock().unwrap().len() >= max {
        return loader_throw(
            scope,
            &format!("worker loader: too many loaded workers (limit {max})"),
        );
    }

    let id = LOADER_NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let handle = match tokio::runtime::Handle::try_current() {
        Ok(handle) => handle,
        Err(error) => return loader_throw(scope, &format!("worker loader: {error}")),
    };
    let (loaded, state) = tokio::sync::watch::channel(LoaderState::Loading);
    loader_registry()
        .lock()
        .unwrap()
        .insert(id, LoaderEntry { owner, state });
    scope.set_slot(SelfLoaderId(id));
    handle.spawn(async move {
        let state = match tokio::task::spawn_blocking(move || Worker::load_config(config)).await {
            Ok(Ok(worker)) => LoaderState::Ready(crate::pool::Slot::standalone(worker)),
            Ok(Err(error)) => LoaderState::Failed(Arc::from(format!("{error}"))),
            Err(error) => LoaderState::Failed(Arc::from(format!(
                "worker loader: load task failed: {error}"
            ))),
        };
        loaded.send_replace(state);
    });
    rv.set(v8::Number::new(scope, id as f64).into());
}

'''
replace_once(js_rs, loader_self_anchor, loader_self_impl + loader_self_anchor)

old_ctx_exports = '''// ctx.exports: loopback stubs for every exported entrypoint plus
// this worker's Durable Object namespaces. Built once, on first
// access — ctx construction itself only carries the getter.
let __ctxExportsCache;
const __ctxExports = () => __ctxExportsCache ??= (() => {
  const out = {};
  for (const name of Object.keys(__cell.entrypoints))
    out[name] = __entrypointStub(name, undefined);
  for (const name of Object.keys(__cell.objectEntrypoints))
    if (name !== "default")
      out[name] = __entrypointStub(name, undefined);
  for (const name of Object.keys(__cell.namespaceKeys))
    out[name] = __cell.makeNamespace(name);
  return out;
})();'''
new_ctx_exports = '''// ctx.exports: loopback stubs for exported WorkerEntrypoints and callable
// DurableObjectClass factories for this worker's own DO classes. Workerd's
// ctx.exports.SomeDurableObject({ props }) returns a class descriptor suitable
// for ctx.facets.get(); env bindings remain DurableObjectNamespace objects.
let __ctxExportsCache;
let __selfLoaderId;
const __selfDurableObjectClass = (name) => (options = {}) =>
  __makeDurableObjectClass(
    Promise.resolve(__selfLoaderId ??= __loader_self()), name, options);
const __ctxExports = () => __ctxExportsCache ??= (() => {
  const out = {};
  for (const name of Object.keys(__cell.entrypoints))
    out[name] = __entrypointStub(name, undefined);
  for (const name of Object.keys(__cell.objectEntrypoints))
    if (name !== "default")
      out[name] = __entrypointStub(name, undefined);
  for (const name of Object.keys(__cell.doExports))
    if (!name.startsWith("__") && name !== ".cron")
      out[name] = __selfDurableObjectClass(name);
  return out;
})();'''
replace_once(harness, old_ctx_exports, new_ctx_exports)

print(
    "Applied AgentOS Cloudflare OS compatibility patch: "
    "service env bridge + cross-isolate entrypoint props + ctx.exports facets"
)
