let input = Buffer.alloc(0);
let active = null;
let neverStops = false;
let sequence = 0;
function send(value) {
  const body = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length);
  process.stdout.write(Buffer.concat([header, body]));
}
function event(runID, type, data = {}) {
  send({ jsonrpc: "2.0", method: "event", params: { runID, sequence: ++sequence, type, ...data } });
}
process.stdin.on("data", chunk => {
  input = Buffer.concat([input, chunk]);
  while (input.length >= 4 && input.length >= input.readUInt32BE(0) + 4) {
    const length = input.readUInt32BE(0);
    const message = JSON.parse(input.subarray(4, length + 4));
    input = input.subarray(length + 4);
    if (message.method === "run") {
      const runID = message.params.runID;
      send({ jsonrpc: "2.0", id: message.id, result: { accepted: true } });
      if (active) event(runID, "error", { message: "previous run is still active" });
      else if (message.params.prompt === "first" || message.params.prompt === "stuck") {
        active = runID;
        neverStops = message.params.prompt === "stuck";
        event(runID, "text_delta", { text: "ready" });
      } else event(runID, "completed", { modelRequests: 1, stopReason: "stop" });
    } else if (message.method === "cancel") {
      const runID = message.params.runID;
      send({ jsonrpc: "2.0", id: message.id, result: { cancelled: true } });
      if (!neverStops) setTimeout(() => { active = null; event(runID, "cancelled"); }, 500);
    }
  }
});
