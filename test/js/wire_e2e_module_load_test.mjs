// Loads the real compiled fixture client modules.
//
// Run from repo root:
//   test/js/wire_e2e_setup.sh
//   node test/js/wire_e2e_module_load_test.mjs

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";

const buildRoot = readFileSync("test/js/.wire_e2e_build_root", "utf8").trim();
if (!buildRoot) {
  throw new Error("wire E2E build root is empty; run test/js/wire_e2e_setup.sh");
}

const webRoot = join(buildRoot, "clients/web/build/dev/javascript/web");

async function importBuilt(relativePath) {
  const url = pathToFileURL(join(webRoot, relativePath)).href;
  return import(url);
}

await importBuilt("generated/rpc_decoders_ffi.mjs");
await importBuilt("generated/rpc_decoders.mjs");
await importBuilt("generated/messages.mjs");
await importBuilt("app.mjs");

console.log("wire e2e module-load test passed");
