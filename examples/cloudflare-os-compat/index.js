import { DurableObject, RpcStub, RpcTarget, WorkerEntrypoint, restore } from "cloudflare:workers";
import TEXT_FIXTURE from "./fixture.txt";

// This example is intentionally modeled after the primitives Cloudflare OS
// relies on for Code Mode and Gatekeepers. Keep it small: if this works, we
// know celld has the runtime semantics we need without booting Cloudflare OS.

export class EchoNoProps extends WorkerEntrypoint {
  echo(value) {
    return `service:${value}`;
  }
}

export class EchoTool extends WorkerEntrypoint {
  async echo(value) {
    return `${this.ctx.props.prefix}:${value}`;
  }
}

export class ClassProvider extends WorkerEntrypoint {
  getFacetClass() {
    return this.ctx.exports.FacetTool({ props: { prefix: "rpc-class" } });
  }
}

export class TailSink extends WorkerEntrypoint {
  async tail(events) {
    await this.env.TEST_KV.put("tail-trace", JSON.stringify(events[0]));
  }
}

class TransientTool extends RpcTarget {
  echo(value) {
    return `transient:${value}`;
  }
}

class ReturnedTool extends RpcTarget {
  echo(value) {
    return `returned:${value}`;
  }
}

class RestoredTool extends RpcTarget {
  constructor(prefix) {
    super();
    this.prefix = prefix;
  }
  echo(value) {
    return `${this.prefix}:${value}`;
  }
}

export class FacetTool extends DurableObject {
  async echo(value) {
    return `${this.ctx.props.prefix}:${value}`;
  }

  returnRpcTarget() {
    return new ReturnedTool();
  }

  async callCapability(tool, value) {
    return tool.echo(value);
  }
}

export class DirectTool extends DurableObject {
  echo(value) {
    return `direct:${value}`;
  }
}

export class FacetHost extends DurableObject {
  #tool() {
    // Cloudflare OS creates Gatekeeper facets from props-bearing classes
    // obtained through ctx.exports. celld v0.4.1 documents this exact shape
    // as unsupported; this is the regression test that must turn green.
    const facetClass = this.ctx.exports.FacetTool({
      props: { prefix: "facet" },
    });
    return this.ctx.facets.get("tool", () => ({
      id: "tool",
      class: facetClass,
    }));
  }

  async call(value) {
    return this.#tool().echo(value);
  }

  async callReturnedClass(value) {
    const cls = await this.ctx.exports.ClassProvider.getFacetClass();
    const facet = this.ctx.facets.get("rpc-returned-class", () => ({
      id: "rpc-returned-class",
      class: cls,
    }));
    return facet.echo(value);
  }

  async callFacetReturnedRpcTarget(value) {
    const tool = await this.#tool().returnRpcTarget();
    return tool.echo(value);
  }

  async callFacetCapability(value) {
    return this.#tool().callCapability(new ReturnedTool(), value);
  }

  async callFacetServiceCapability(value) {
    const tool = this.ctx.exports.EchoTool({ props: { prefix: "svc-roundtrip" } });
    return this.#tool().callCapability(tool, value);
  }

  returnTool() {
    return new ReturnedTool();
  }

  async callLoaderDoOnly(value) {
    const worker = this.env.LOADER.load({
      compatibilityDate: "2026-09-07",
      mainModule: "worker.js",
      modules: { "worker.js": DO_ONLY_DYNAMIC_WORKER },
      globalOutbound: null,
    });
    const cls = worker.getDurableObjectClass("Gadget");
    const facet = this.ctx.facets.get("do-only", () => ({
      id: "do-only",
      class: cls,
    }));
    return facet.echo(value);
  }

  #forgerEntrypoint() {
    return this.env.LOADER.load({
      compatibilityDate: "2026-09-07",
      compatibilityFlags: ["allow_irrevocable_stub_storage"],
      mainModule: "forger.js",
      modules: { "forger.js": RESTORE_FORGER_DYNAMIC_WORKER },
      globalOutbound: null,
    }).getEntrypoint();
  }

  #restoreTargetFacet() {
    const worker = this.env.LOADER.load({
      compatibilityDate: "2026-09-07",
      compatibilityFlags: ["allow_irrevocable_stub_storage"],
      mainModule: "worker.js",
      modules: { "worker.js": RESTORE_TARGET_DYNAMIC_WORKER },
      globalOutbound: null,
    });
    const cls = worker.getDurableObjectClass("Gadget");
    return this.ctx.facets.get("restore-target", () => ({
      id: "restore-target",
      class: cls,
    }));
  }

  async [restore](params) {
    if (params?.type === "forger") return this.#forgerEntrypoint();
    if (params?.type === "switch") {
      return await this.ctx.storage.get("switch-to-facet")
        ? this.#restoreTargetFacet()
        : this.#forgerEntrypoint();
    }
    return new RestoredTool(params.prefix);
  }

  async restoreRoundTrip(value) {
    const live = await this.ctx.restore({ prefix: "restored" });
    const immediate = await live.echo(value);
    await this.ctx.storage.put("persistent-restore-stub", live);
    const stored = await this.ctx.storage.get("persistent-restore-stub");
    return `${immediate}/${await stored.echo(value)}`;
  }

  async storeRestoreStub() {
    const live = await this.ctx.restore({ prefix: "restarted" });
    await this.ctx.storage.put("persistent-restart-stub", live);
    return "stored";
  }

  async readRestoreStub(value) {
    const stored = await this.ctx.storage.get("persistent-restart-stub");
    if (stored === undefined) throw new Error("persistent restore stub was not stored");
    return stored.echo(value);
  }

  async nestedRestoreRoundTrip(value) {
    let forger;
    try {
      forger = await this.ctx.restore({ type: "forger" });
    } catch (error) {
      throw new Error("outer restore: " + error);
    }
    let forged;
    try {
      forged = await forger.forge({ prefix: "forged" });
    } catch (error) {
      throw new Error("forge: " + error);
    }
    try {
      await this.ctx.storage.put("nested-restore-stub", forged);
    } catch (error) {
      throw new Error("store: " + error);
    }
    let stored;
    try {
      stored = await this.ctx.storage.get("nested-restore-stub");
    } catch (error) {
      throw new Error("read: " + error);
    }
    if (stored === undefined) throw new Error("nested restore stub was not stored");
    try {
      return await stored.echo(value);
    } catch (error) {
      throw new Error("call: " + error);
    }
  }


  async storeNestedRestoreStub() {
    const forger = await this.ctx.restore({ type: "forger" });
    const forged = await forger.forge({ prefix: "nested-restarted" });
    await this.ctx.storage.put("nested-restart-stub", forged);
    return "stored";
  }

  async readNestedRestoreStub(value) {
    const stored = await this.ctx.storage.get("nested-restart-stub");
    if (stored === undefined) throw new Error("nested restart stub was not stored");
    return stored.echo(value);
  }


  async storeSwitchRestoreStub() {
    await this.ctx.storage.put("switch-to-facet", false);
    const forger = await this.ctx.restore({ type: "switch" });
    const forged = await forger.forge({ prefix: "facet-switched" });
    await this.ctx.storage.put("switch-restore-stub", forged);
    await this.ctx.storage.put("switch-to-facet", true);
    return "stored";
  }

  async readSwitchRestoreStub(value) {
    const stored = await this.ctx.storage.get("switch-restore-stub");
    if (stored === undefined) throw new Error("switch restore stub was not stored");
    return stored.echo(value);
  }

  async storeDurableClass() {
    const cls = await this.ctx.exports.ClassProvider.getFacetClass();
    await this.ctx.storage.put("stored-durable-class", cls);
    return "stored";
  }

  async readDurableClass(value) {
    const cls = await this.ctx.storage.get("stored-durable-class");
    if (cls === undefined) throw new Error("DurableObjectClass was not stored");
    const facet = this.ctx.facets.get("stored-durable-class", () => ({
      id: "stored-durable-class",
      class: cls,
    }));
    return facet.echo(value);
  }

  async storeDurableClassInSyncRecord() {
    const cls = await this.ctx.exports.ClassProvider.getFacetClass();
    this.ctx.storage.transactionSync((transaction) => {
      transaction.kv.put("sync-durable-class-record", {
        id: 7,
        class: cls,
        creationSpec: { type: "ambient", vendorId: "context", accountId: 0 },
      });
    });
    return "stored";
  }

  async readDurableClassFromSyncRecord(value) {
    const record = this.ctx.storage.transactionSync((transaction) =>
      transaction.kv.get("sync-durable-class-record"));
    if (record?.class === undefined) throw new Error("nested DurableObjectClass was not stored");
    const facet = this.ctx.facets.get("sync-durable-class-record", () => ({
      id: "sync-durable-class-record",
      class: record.class,
    }));
    return facet.echo(value);
  }
}

const PLAIN_DYNAMIC_WORKER = `
export default {
  fetch() {
    return Response.json({ ok: true, kind: "plain-dynamic-worker" });
  },
};
`;

const CAPABILITY_DYNAMIC_WORKER = `
export default {
  async fetch(request, env) {
    const value = new URL(request.url).searchParams.get("value") ?? "hello";
    return Response.json({ result: await env.TOOL.echo(value) });
  },
};
`;

const TRANSIENT_DYNAMIC_WORKER = `
import { WorkerEntrypoint } from "cloudflare:workers";

export default class extends WorkerEntrypoint {
  async run(tool, value) {
    return tool.echo(value);
  }
}
`;

const TAIL_DYNAMIC_WORKER = `
import { WorkerEntrypoint } from "cloudflare:workers";

export default class extends WorkerEntrypoint {
  run() {
    console.log("tail-probe");
    return "done";
  }
}
`;

const DO_ONLY_DYNAMIC_WORKER = `
import { DurableObject } from "cloudflare:workers";
export class Gadget extends DurableObject {
  echo(value) {
    return "do-only:" + value;
  }
}
`;


const RESTORE_FORGER_DYNAMIC_WORKER = `
import { RpcTarget, WorkerEntrypoint, restore } from "cloudflare:workers";
class ForgedTool extends RpcTarget {
  constructor(prefix) {
    super();
    this.prefix = prefix;
  }
  echo(value) {
    return this.prefix + ":" + value;
  }
}
export default class extends WorkerEntrypoint {
  forge(params) {
    return this.ctx.restore(params);
  }
  [restore](params) {
    return new ForgedTool(params.prefix);
  }
}
`;


const RESTORE_TARGET_DYNAMIC_WORKER = `
import { DurableObject, RpcTarget, restore } from "cloudflare:workers";
class RestoredTarget extends RpcTarget {
  constructor(prefix) {
    super();
    this.prefix = prefix;
  }
  echo(value) {
    return this.prefix + ":" + value;
  }
}
export class Gadget extends DurableObject {
  [restore](params) {
    return new RestoredTarget(params.prefix);
  }
}
`;

function load(env, code, extraEnv = {}) {
  return env.LOADER.load({
    compatibilityDate: "2026-09-07",
    mainModule: "worker.js",
    modules: { "worker.js": code },
    env: extraEnv,
    globalOutbound: null,
  });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/text-module") {
      return Response.json({ result: TEXT_FIXTURE.trim() });
    }

    if (url.pathname === "/plain") {
      return load(env, PLAIN_DYNAMIC_WORKER).getEntrypoint().fetch(request);
    }

    if (url.pathname === "/json-var") {
      return Response.json(env.JSON_CONFIG);
    }

    if (url.pathname === "/kv-preview") {
      await env.TEST_KV.put("smoke", "preview-id");
      return Response.json({ result: await env.TEST_KV.get("smoke") });
    }

    if (url.pathname === "/service") {
      const tool = ctx.exports.EchoNoProps;
      return load(env, CAPABILITY_DYNAMIC_WORKER, { TOOL: tool })
        .getEntrypoint()
        .fetch(request);
    }

    if (url.pathname === "/capability") {
      // This is the canonical Dynamic Workers custom-binding pattern:
      // create a props-scoped loopback WorkerEntrypoint stub and pass it into
      // the dynamic Worker's env. Cloudflare OS uses this for binding loopbacks.
      const tool = ctx.exports.EchoTool({ props: { prefix: "capability" } });
      return load(env, CAPABILITY_DYNAMIC_WORKER, { TOOL: tool })
        .getEntrypoint()
        .fetch(request);
    }

    if (url.pathname === "/transient") {
      // Cloudflare OS also passes transient RpcTargets as arguments to the
      // loaded Code Mode entrypoint (e.g. RestoreForgerImpl). Those cannot be
      // reduced to a durable service descriptor and therefore exercise the
      // actual cross-isolate RPC-handle path.
      const result = await load(env, TRANSIENT_DYNAMIC_WORKER)
        .getEntrypoint()
        .run(new TransientTool(), "hello");
      return Response.json({ result });
    }

    if (url.pathname === "/rpc-promise-dispose") {
      const tool = ctx.exports.EchoTool({ props: { prefix: "rpc-promise" } });
      const pending = tool.echo("hello");
      const disposable = typeof pending[Symbol.dispose] === "function";
      const result = await pending;
      pending[Symbol.dispose]?.();
      return Response.json({ result, disposable });
    }

    if (url.pathname === "/tail") {
      await env.TEST_KV.delete("tail-trace");
      const worker = env.LOADER.load({
        compatibilityDate: "2026-09-07",
        mainModule: "worker.js",
        modules: { "worker.js": TAIL_DYNAMIC_WORKER },
        tails: [ctx.exports.TailSink],
        globalOutbound: null,
      });
      await worker.getEntrypoint().run();
      const raw = await env.TEST_KV.get("tail-trace");
      const trace = raw === null ? null : JSON.parse(raw);
      return Response.json({
        method: trace?.event?.rpcMethod,
        log: trace?.logs?.[0]?.message?.[0],
      });
    }

    if (url.pathname === "/facet") {
      const host = env.FACET_HOST.getByName("cloudflare-os-compat");
      return Response.json({ result: await host.call("hello") });
    }

    if (url.pathname === "/rpc-durable-class") {
      const host = env.FACET_HOST.getByName("rpc-durable-class");
      return Response.json({ result: await host.callReturnedClass("hello") });
    }

    if (url.pathname === "/facet-return-rpc") {
      const host = env.FACET_HOST.getByName("facet-return-rpc");
      return Response.json({ result: await host.callFacetReturnedRpcTarget("hello") });
    }

    if (url.pathname === "/facet-capability-arg") {
      const host = env.FACET_HOST.getByName("facet-capability-arg");
      return Response.json({ result: await host.callFacetCapability("hello") });
    }

    if (url.pathname === "/facet-service-props-roundtrip") {
      const host = env.FACET_HOST.getByName("facet-service-props-roundtrip");
      return Response.json({ result: await host.callFacetServiceCapability("hello") });
    }

    if (url.pathname === "/ctx-exports-do") {
      const tool = ctx.exports.DirectTool.getByName("direct-tool");
      return Response.json({ result: await tool.echo("hello") });
    }

    if (url.pathname === "/do-return-rpc") {
      const host = env.FACET_HOST.getByName("rpc-return");
      const tool = await host.returnTool();
      return Response.json({ result: await tool.echo("hello") });
    }

    if (url.pathname === "/do-return-rpc-pipeline") {
      const host = env.FACET_HOST.getByName("rpc-return-pipeline");
      return Response.json({ result: await host.returnTool().echo("hello") });
    }

    if (url.pathname === "/proxy-rpc-target") {
      const target = new Proxy({}, {
        getPrototypeOf() { return RpcTarget.prototype; },
        get(_target, prop) {
          if (prop === "greet") return (name) => `proxy:${name}`;
          return undefined;
        },
      });
      using stub = new RpcStub(target);
      return Response.json({ result: await stub.greet("hello") });
    }

    if (url.pathname === "/loader-do-only") {
      const host = env.FACET_HOST.getByName("loader-do-only");
      return Response.json({ result: await host.callLoaderDoOnly("hello") });
    }

    if (url.pathname === "/persistent-restore") {
      const host = env.FACET_HOST.getByName("persistent-restore");
      return Response.json({ result: await host.restoreRoundTrip("hello") });
    }

    if (url.pathname === "/persistent-restore-store") {
      const host = env.FACET_HOST.getByName("persistent-restart");
      return Response.json({ result: await host.storeRestoreStub() });
    }

    if (url.pathname === "/persistent-restore-read") {
      const host = env.FACET_HOST.getByName("persistent-restart");
      return Response.json({ result: await host.readRestoreStub("hello") });
    }

    if (url.pathname === "/nested-restore-forger") {
      const host = env.FACET_HOST.getByName("nested-restore-forger");
      return Response.json({ result: await host.nestedRestoreRoundTrip("hello") });
    }

    if (url.pathname === "/nested-restore-store") {
      const host = env.FACET_HOST.getByName("nested-restart");
      return Response.json({ result: await host.storeNestedRestoreStub() });
    }

    if (url.pathname === "/nested-restore-read") {
      const host = env.FACET_HOST.getByName("nested-restart");
      return Response.json({ result: await host.readNestedRestoreStub("hello") });
    }

    if (url.pathname === "/switch-restore-store") {
      const host = env.FACET_HOST.getByName("switch-restart");
      return Response.json({ result: await host.storeSwitchRestoreStub() });
    }

    if (url.pathname === "/switch-restore-read") {
      const host = env.FACET_HOST.getByName("switch-restart");
      return Response.json({ result: await host.readSwitchRestoreStub("hello") });
    }

    if (url.pathname === "/durable-class-store") {
      const host = env.FACET_HOST.getByName("durable-class-restart");
      return Response.json({ result: await host.storeDurableClass() });
    }

    if (url.pathname === "/durable-class-read") {
      const host = env.FACET_HOST.getByName("durable-class-restart");
      return Response.json({ result: await host.readDurableClass("hello") });
    }

    if (url.pathname === "/sync-durable-class-store") {
      const host = env.FACET_HOST.getByName("sync-durable-class-restart");
      return Response.json({ result: await host.storeDurableClassInSyncRecord() });
    }

    if (url.pathname === "/sync-durable-class-read") {
      const host = env.FACET_HOST.getByName("sync-durable-class-restart");
      return Response.json({ result: await host.readDurableClassFromSyncRecord("hello") });
    }

    return Response.json({
      endpoints: ["/plain", "/json-var", "/kv-preview", "/service", "/capability", "/transient", "/tail", "/facet", "/rpc-durable-class", "/ctx-exports-do", "/do-return-rpc", "/proxy-rpc-target", "/loader-do-only", "/persistent-restore", "/nested-restore-forger", "/nested-restore-store", "/nested-restore-read", "/switch-restore-store", "/switch-restore-read"],
    });
  },
};
