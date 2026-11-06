import { readFile } from "node:fs/promises";
import { runtimeSelfTest } from "./runtime-selftest.mjs";
import { resourceLoader } from "./runtime-resource-loader.mjs";
import { toolCatalog } from "./tool-catalog.mjs";

try {
  const metadata = JSON.parse(await readFile(new URL("./node_modules/@earendil-works/pi-coding-agent/package.json", import.meta.url), "utf8"));
  const result = await runtimeSelfTest(resourceLoader);
  process.stdout.write(JSON.stringify({ ...result, piVersion: metadata.version, toolNames: Object.keys(toolCatalog).sort() }));
} catch {
  process.stderr.write("Runtime health check failed\n");
  process.exitCode = 1;
}
