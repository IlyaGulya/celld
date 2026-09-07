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

# Install a recursive reviver because props may themselves contain plain data
# structures. Nested capabilities are deliberately left for the generic bridge.
anchor = '''globalThis.__makeServiceBinding = (script, entrypoint = null) => {\n'''
reviver = '''globalThis.__reviveLoaderEnv = (env) => {
  const seen = new Map();
  const revive = (value) => {
    if (value === null || typeof value !== "object") return value;
    const cached = seen.get(value);
    if (cached !== undefined) return cached;
    const entrypoint = value["__celld$loaderSvc"];
    if (entrypoint !== undefined) {
      // Props are carried in the marker now so transport does not need another
      // format change. Applying them on the target is the next TDD step.
      return globalThis.__makeServiceBinding(value.s, entrypoint);
    }
    const out = Array.isArray(value) ? [] : {};
    seen.set(value, out);
    for (const [key, child] of Object.entries(value)) out[key] = revive(child);
    return out;
  };
  return revive(env);
};

globalThis.__makeServiceBinding = (script, entrypoint = null) => {
'''
replace_once(harness, anchor, reviver)

bootstrap = ROOT / "crates/celld/js/bootstrap.rs"
old_bootstrap = '''        // A loaded worker's caller-supplied `env` (plain JSON values only in
        // the walking skeleton) merges last, over the declared bindings.
        if let Some(env) = config.loader_env.as_deref() {
            lines.push_str(&format!("Object.assign(e, {});\\
", env));
        }
'''
new_bootstrap = '''        // A loaded worker's caller-supplied env merges last, over declared
        // bindings. The harness revives portable capability descriptors before
        // exposing them to user code.
        if let Some(env) = config.loader_env.as_deref() {
            lines.push_str(&format!("Object.assign(e, __reviveLoaderEnv({}));\\
", env));
        }
'''
replace_once(bootstrap, old_bootstrap, new_bootstrap)

print("Applied AgentOS Cloudflare OS compatibility patch: service env bridge")
