/* Node regression harness for the WebGPU canvas configuration guard.
 * The production module is imported through a data URL because the panel does
 * not need a package.json merely to declare its browser files as ES modules.
 * A successfully configured browser additionally has to pass the live shader
 * pixel readback in createHdrRenderer(); that GPU path cannot be faked here.
 */

import fs from "node:fs";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repository = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const modulePath = path.join(
  repository, "apps", "panel", "web", "js", "preview", "gpu.js");
const source = fs.readFileSync(modulePath, "utf8");
const { createHdrRenderer } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

Object.defineProperty(globalThis, "GPUTextureUsage", {
  configurable: true,
  value: { COPY_SRC: 1, RENDER_ATTACHMENT: 16 },
});

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

// Exercise real packet views and the production texture upload. The GPU is a
// recording stub here; shader/display correctness still needs a real device.
const packetSource = fs.readFileSync(path.join(repository,
  "apps/panel/web/js/preview/packet.js"), "utf8")
  .replace('import { t } from "../i18n/index.js";', 'const t = value => value;');
const { decodePreview } = await import(
  `data:text/javascript;base64,${Buffer.from(packetSource).toString("base64")}`);
Object.assign(GPUTextureUsage, { TEXTURE_BINDING: 4, COPY_DST: 2 });
globalThis.GPUBufferUsage = { COPY_DST: 1, MAP_READ: 2, UNIFORM: 4 };
globalThis.GPUMapMode = { READ: 1 };
const uploads = [];
const pass = { setPipeline() {}, setBindGroup() {}, draw() {}, end() {} };
const device = {
  queue: {
    writeTexture(target, data, layout, size) {
      uploads.push({ target, data: data.slice(), layout, size });
    },
    writeBuffer() {}, submit() {},
  },
  createTexture(descriptor) {
    return { descriptor, createView() { return {}; }, destroy() {} };
  },
  createBuffer() {
    return { async mapAsync() {},
      getMappedRange() { return new Uint16Array([0x3f4d, 0x3762, 0, 0x3c00]).buffer; },
      unmap() {}, destroy() {} };
  },
  createShaderModule() { return {}; },
  async createRenderPipelineAsync() { return { getBindGroupLayout() { return {}; } }; },
  createBindGroup() { return {}; },
  createCommandEncoder() {
    return { beginRenderPass() { return pass; }, copyTextureToBuffer() {}, finish() {} };
  },
  lost: new Promise(() => {}), destroy() {},
};
navigator.gpu.requestAdapter = async () => ({ requestDevice: async () => device });
const context = {
  configure(configuration) { this.configuration = configuration; },
  getConfiguration() { return this.configuration; }, unconfigure() {},
};
const renderer = await createHdrRenderer({ getContext: () => context });
try {
  for (const width of [3, 64]) {
    const height = 3;
    const base = new Float32Array(width * height * 3).fill(0.18);
    const gain = Float32Array.from({ length: width * height }, (_, i) => i / (width * height));
    let header = JSON.stringify({ width, height, gainWidth: width, gainHeight: height,
      gainMin: 0, gainMax: 2, gainGamma: 1, baseOffset: 0, alternateOffset: 0 });
    header = header.padEnd(Math.ceil(header.length / 4) * 4, " ");
    const offset = 12 + header.length;
    const bytes = new Uint8Array(offset + base.byteLength + gain.byteLength);
    bytes.set(new TextEncoder().encode("HYPREV2\n"));
    new DataView(bytes.buffer).setUint32(8, header.length, true);
    bytes.set(new TextEncoder().encode(header), 12);
    bytes.set(new Uint8Array(base.buffer), offset);
    bytes.set(new Uint8Array(gain.buffer), offset + base.byteLength);
    const frame = decodePreview(bytes.buffer);
    assert.equal(frame.gain.buffer, bytes.buffer, "gain is a view into the packet");
    renderer.upload(frame);
    const uploaded = uploads.at(-1);
    assert.equal(uploaded.target.texture.descriptor.format, "r32float");
    assert.deepEqual(uploaded.size, [width, height]);
    assert.equal(uploaded.data.byteLength, uploaded.layout.bytesPerRow * height);
    for (let y = 0; y < height; y++) {
      const row = new Float32Array(uploaded.data.buffer, y * uploaded.layout.bytesPerRow, width);
      assert.deepEqual(row, gain.subarray(y * width, (y + 1) * width),
        `gain row ${y} at width ${width} must not contain the packet header or base`);
    }
  }
} finally { renderer.destroy(); }
console.log("HDR configuration and compact gain upload rows passed");
