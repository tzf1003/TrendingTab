import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { runtimeSelfTest } from "./runtime-selftest.mjs";
import { resourceLoader } from "./runtime-resource-loader.mjs";
import { toolCatalog } from "./tool-catalog.mjs";

try {
  const metadata = JSON.parse(await readFile(new URL("./node_modules/@earendil-works/pi-coding-agent/package.json", import.meta.url), "utf8"));
  if (process.platform === "darwin") {
    const helper = createRequire(import.meta.url)(fileURLToPath(new URL(
      `./node_modules/@earendil-works/pi-tui/native/darwin/prebuilds/darwin-${process.arch}/darwin-platform.node`, import.meta.url)));
    if (typeof helper.getText !== "function" || typeof helper.getImage !== "function") {
      throw new Error("Native Pi helper unavailable");
    }
  }
  const result = await runtimeSelfTest(resourceLoader);
  process.stdout.write(JSON.stringify({ ...result, architecture: process.arch, piVersion: metadata.version, toolNames: Object.keys(toolCatalog).sort() }));
} catch {
  process.stderr.write("Runtime health check failed\n");
  process.exitCode = 1;
}
