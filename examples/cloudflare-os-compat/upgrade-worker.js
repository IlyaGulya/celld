import { DurableObject } from "cloudflare:workers";

export class UpgradeCounter extends DurableObject {
  async set(value) {
    await this.ctx.storage.put("value", Number(value));
    return Number(value);
  }

  async get() {
    return await this.ctx.storage.get("value") ?? 0;
  }
}

export default {
  async fetch(request, env) {
    const counter = env.UPGRADE_COUNTER.getByName("rolling-upgrade");
    const path = new URL(request.url).pathname;
    if (path === "/prime") return Response.json({ value: await counter.set(3) });
    if (path === "/get") return Response.json({ value: await counter.get() });
    return new Response("not found", { status: 404 });
  },
};
