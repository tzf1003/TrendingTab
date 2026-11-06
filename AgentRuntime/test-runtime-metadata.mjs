import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, copyFile, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const source = fileURLToPath(new URL(".", import.meta.url));
const directory = await mkdtemp(join(tmpdir(), "trendingtab-runtime-metadata-"));
let child;
try {
  for (const name of await readdir(source)) {
    if (name.endsWith(".mjs")) await copyFile(join(source, name), join(directory, name));
  }
  await symlink(join(source, "node_modules"), join(directory, "node_modules"), "dir");
  const metadata = JSON.parse(await readFile(join(source, "package.json"), "utf8"));
  metadata.version = "9.8.7";
  await writeFile(join(directory, "package.json"), JSON.stringify(metadata));
  const pi = JSON.parse(await readFile(join(source, "node_modules/@earendil-works/pi-coding-agent/package.json"), "utf8"));
  child = spawn(process.execPath, [join(directory, "runtime.mjs")], { stdio: ["pipe", "pipe", "pipe"] });
  const body = Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "hello" }));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length);
  child.stdin.write(Buffer.concat([header, body]));
  const reply = await new Promise((resolve, reject) => {
    let bytes = Buffer.alloc(0);
    const timer = setTimeout(() => reject(new Error("Runtime handshake timed out")), 10000);
    child.on("error", reject);
    child.on("exit", code => reject(new Error(`Runtime exited: ${code}`)));
    child.stdout.on("data", chunk => {
      bytes = Buffer.concat([bytes, chunk]);
      if (bytes.length < 4 || bytes.length < 4 + bytes.readUInt32BE()) return;
      clearTimeout(timer);
      resolve(JSON.parse(bytes.subarray(4, 4 + bytes.readUInt32BE()).toString()));
    });
  });
  assert.equal(reply.result.runtime, "9.8.7");
  assert.equal(reply.result.pi, pi.version);
  console.log("Runtime handshake reports actual package versions");
} finally {
  if (child) {
    child.kill();
    await new Promise(resolve => child.once("close", resolve));
  }
  await rm(directory, { recursive: true, force: true });
}
