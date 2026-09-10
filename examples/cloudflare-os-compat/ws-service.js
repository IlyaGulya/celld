import { DurableObject, WorkerEntrypoint } from "cloudflare:workers";

export class ChildEntrypoint extends WorkerEntrypoint {
  echo(value) {
    return `${this.ctx.props.prefix}:${value}`;
  }
}

export class ChildDurableObject extends DurableObject {
  echo(value) {
    return `${this.ctx.props.prefix}:${value}`;
  }
}
export class PropsEntrypoint extends WorkerEntrypoint {
  echo(value) {
    return `${this.ctx.props.prefix}:${value}`;
  }

  createChild(prefix) {
    return this.ctx.exports.ChildEntrypoint({ props: { prefix } });
  }

  getChildClass(prefix) {
    return this.ctx.exports.ChildDurableObject({ props: { prefix } });
  }
}
export default {
  fetch(request) {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket required", { status: 426 });
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();
    server.addEventListener("message", (event) => {
      server.send("service:" + event.data);
    });
    return new Response(null, { status: 101, webSocket: client });
  },
};
