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
}

export default {
  async fetch(request, env) {
    const host = env.HOST.getByName("phase0");
    const path = new URL(request.url).pathname;
    if (path === "/prime") {
      return Response.json({ result: await host.prime() });
    }
    if (path === "/call") {
      const tool = await host.tool();
      return Response.json({ result: await tool.echo("hello") });
    }
    return new Response("not found", { status: 404 });
  },
};
