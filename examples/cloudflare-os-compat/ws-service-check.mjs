const url = process.argv[2];
if (!url) throw new Error("usage: node ws-service-check.mjs ws://host:port/");

const socket = new WebSocket(url);
const timeout = setTimeout(() => {
  try { socket.close(); } catch {}
  console.error("WebSocket service-binding smoke timed out");
  process.exit(1);
}, 5000);

socket.addEventListener("open", () => socket.send("hello"));
socket.addEventListener("message", (event) => {
  clearTimeout(timeout);
  const value = typeof event.data === "string" ? event.data : String(event.data);
  if (value !== "service:hello") {
    console.error(`unexpected WebSocket reply: ${value}`);
    process.exit(1);
  }
  console.log(value);
  socket.close();
  process.exit(0);
});
socket.addEventListener("error", () => {
  clearTimeout(timeout);
  console.error("WebSocket service-binding connection failed");
  process.exit(1);
});
