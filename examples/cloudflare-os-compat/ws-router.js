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
    return env.SERVICE.fetch(request);
  },
};
