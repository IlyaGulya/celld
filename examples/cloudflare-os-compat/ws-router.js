import { DurableObject } from "cloudflare:workers";


export class ClassRelay extends DurableObject {
  getClass(prefix) {
    return this.env.PROPS.getChildClass(prefix);
  }
}
export class ClassHost extends DurableObject {
  async call(value) {
    const cls = await this.env.PROPS.getChildClass("remote-class");
    const facet = this.ctx.facets.get("remote-class", () => ({
      id: "remote-class",
      class: cls,
    }));
    return facet.echo(value);
  }

  async callRelayed(value) {
    const cls = await this.env.CLASS_RELAY.getByName("relay").getClass("relayed-class");
    const facet = this.ctx.facets.get("relayed-class", () => ({
      id: "relayed-class",
      class: cls,
    }));
    return facet.echo(value);
  }

  async storeServiceStub() {
    const account = await this.env.PROPS.createChild("stored-service");
    this.ctx.storage.transactionSync((transaction) => {
      transaction.kv.put("stored-service-record", {
        id: 1,
        account,
        description: { singleton: { tsType: "Smoke" } },
      });
    });
    return "stored";
  }

  async readServiceStub(value) {
    const record = this.ctx.storage.transactionSync((transaction) =>
      transaction.kv.get("stored-service-record"));
    if (!record?.account) throw new Error("stored service account is missing");
    return record.account.echo(value);
  }
}
export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname === "/props") {
      return Response.json({ result: await env.PROPS.echo("hello") });
    }
    if (new URL(request.url).pathname === "/returned-service-stub") {
      const child = await env.PROPS.createChild("returned-service");
      return Response.json({ result: await child.echo("hello") });
    }
    if (new URL(request.url).pathname === "/returned-do-class") {
      const host = env.CLASS_HOST.getByName("returned-do-class");
      return Response.json({ result: await host.call("hello") });
    }
    if (new URL(request.url).pathname === "/relayed-do-class") {
      const host = env.CLASS_HOST.getByName("relayed-do-class");
      return Response.json({ result: await host.callRelayed("hello") });
    }
    if (new URL(request.url).pathname === "/proxy-entrypoint") {
      return Response.json({ result: await env.PROXY_EP.runAt("hello") });
    }

    if (new URL(request.url).pathname === "/service-stub-store") {
      const host = env.CLASS_HOST.getByName("stored-service");
      return Response.json({ result: await host.storeServiceStub() });
    }
    if (new URL(request.url).pathname === "/service-stub-read") {
      const host = env.CLASS_HOST.getByName("stored-service");
      return Response.json({ result: await host.readServiceStub("hello") });
    }
    return env.SERVICE.fetch(request);
  },
};
