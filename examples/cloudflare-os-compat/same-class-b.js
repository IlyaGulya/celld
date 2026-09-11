import { DurableObject } from "cloudflare:workers";

export class UserAccount extends DurableObject {
  async who() {
    const count = (await this.ctx.storage.get("count") ?? 100) + 10;
    await this.ctx.storage.put("count", count);
    return `b:${count}:${this.ctx.id.name}`;
  }
}

export default {
  async fetch(_request, _env, ctx) {
    return Response.json({ result: await ctx.exports.UserAccount.getByName("shared-name").who() });
  },
};
