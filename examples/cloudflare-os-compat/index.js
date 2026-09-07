import { DurableObject, RpcTarget, WorkerEntrypoint } from "cloudflare:workers";

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

class TransientTool extends RpcTarget {
  echo(value) {
    return `transient:${value}`;
  }
}

export class FacetTool extends DurableObject {
  async echo(value) {
    return `${this.ctx.props.prefix}:${value}`;
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

    if (url.pathname === "/plain") {
      return load(env, PLAIN_DYNAMIC_WORKER).getEntrypoint().fetch(request);
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

    if (url.pathname === "/facet") {
      const host = env.FACET_HOST.getByName("cloudflare-os-compat");
      return Response.json({ result: await host.call("hello") });
    }

    return Response.json({
      endpoints: ["/plain", "/service", "/capability", "/transient", "/facet"],
    });
  },
};
