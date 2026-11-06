let buffered = Buffer.alloc(0);
process.stdin.on("data", chunk => {
  buffered = Buffer.concat([buffered, chunk]);
  if (buffered.length < 4 || buffered.length < 4 + buffered.readUInt32BE(0)) return;
  const size = buffered.readUInt32BE(0);
  const request = JSON.parse(buffered.subarray(4, 4 + size));
  if (request.method !== "run") return;
  const event = { jsonrpc: "2.0", method: "event", params: { runID: request.params.runID, sequence: 1, type: "text_delta", text: "a" } };
  for (let i = 0; i < 2; i++) {
    const body = Buffer.from(JSON.stringify(event));
    const header = Buffer.alloc(4);
    header.writeUInt32BE(body.length);
    process.stdout.write(Buffer.concat([header, body]));
  }
});
