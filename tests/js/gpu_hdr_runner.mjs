/* Node regression harness for the WebGPU canvas configuration guard.
 * The production module is imported through a data URL because the panel does
 * not need a package.json merely to declare its browser files as ES modules.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repository = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const modulePath = path.join(
  repository, "apps", "panel", "web", "js", "preview", "gpu.js");
const source = fs.readFileSync(modulePath, "utf8");
const { createHdrRenderer } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

async function expectRejectedConfiguration(getConfiguration) {
  let requested = null;
  let unconfigured = false;
  let deviceDestroyed = false;
  const device = { destroy() { deviceDestroyed = true; } };
  const context = {
    configure(configuration) { requested = configuration; },
    getConfiguration,
    unconfigure() { unconfigured = true; },
  };
  const adapter = { async requestDevice() { return device; } };
  Object.defineProperty(globalThis, "window", {
    configurable: true, value: { isSecureContext: true },
  });
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { gpu: { async requestAdapter() { return adapter; } } },
  });

  let rejected = false;
  try {
    await createHdrRenderer({ getContext() { return context; } });
  } catch (error) {
    rejected = /HDR configuration/.test(String(error));
  }
  if (!rejected || requested?.toneMapping?.mode !== "extended" ||
      !unconfigured || !deviceDestroyed) {
    throw new Error("unconfirmed WebGPU HDR canvas configuration was accepted");
  }
}

await expectRejectedConfiguration(function () {
  return {
    format: "rgba16float",
    colorSpace: "display-p3",
    alphaMode: "opaque",
    // Simulates a browser that silently ignores the new dictionary member.
  };
});

await expectRejectedConfiguration(undefined);
