import { DurableObject, RpcTarget } from "cloudflare:workers";

class EchoTool extends RpcTarget {
  constructor(value) {
    super();
    this.value = value;
  }
  echo(value) {
    return `cap:${value}:${this.value}`;
  }
}

export class Host extends DurableObject {
  async prime() {
    await this.ctx.storage.put("value", 3);
    return "primed";
  }

  async tool() {
    return new EchoTool(await this.ctx.storage.get("value") ?? 0);
  }

  // The soak writes through the owner and reads back: an acknowledged write has
  // to survive an owner SIGKILL, so the reader asserts the value never moves
  // backwards and never runs ahead of what the writer saw acknowledged.
  async bump() {
    const value = (await this.ctx.storage.get("value") ?? 0) + 1;
    await this.ctx.storage.put("value", value);
    return value;
  }

  async read() {
    return await this.ctx.storage.get("value") ?? 0;
  }
}

export default {
  async fetch(request, env) {
    // A named cell makes ownership observable across a fleet: several cells
    // spread over the nodes, so a gate can check who owns what and that every
    // node can reach every cell through the owner.
    const url = new URL(request.url);
    const host = env.HOST.getByName(url.searchParams.get("cell") ?? "phase0");
    const path = url.pathname;
    if (path === "/prime") {
      return Response.json({ result: await host.prime() });
    }
    if (path === "/call") {
      const tool = await host.tool();
      return Response.json({ result: await tool.echo("hello") });
    }
    if (path === "/bump") {
      return Response.json({ result: await host.bump() });
    }
    if (path === "/value") {
      return Response.json({ result: await host.read() });
    }
    return new Response("not found", { status: 404 });
  },
};
