export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === "/a") return env.A.fetch(request);
    if (path === "/b") return env.B.fetch(request);
    return new Response("not found", { status: 404 });
  },
};
