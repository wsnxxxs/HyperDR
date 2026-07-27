/* WebGPU true-HDR renderer: linear Display P3, extended-range rgba16float.
 *
 * Isolated behind `create()` / `upload()` / `draw()` so the fallback path never
 * has to know whether a device exists, and a lost device simply drops the
 * object rather than leaving half-initialised globals behind.
 */

import { LUT_SIZE } from "./curve.js";

const SHADER = /* wgsl */ `
struct Params {
  strength: f32, headroom: f32, original: f32, expansionStart: f32,
  areaCoverage: f32, exposureBias: f32, lutSize: f32, padding: f32,
}
@group(0) @binding(0) var imageSampler: sampler;
@group(0) @binding(1) var imageTexture: texture_2d<f32>;
@group(0) @binding(2) var<uniform> params: Params;
// The exporter's tone curve, uploaded verbatim by the host each frame.
@group(0) @binding(3) var<storage, read> gainLut: array<f32>;

struct VertexOutput { @builtin(position) position: vec4f, @location(0) uv: vec2f, }

@vertex fn vertexMain(@builtin(vertex_index) index: u32) -> VertexOutput {
  var positions = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  var coordinates = array<vec2f, 3>(vec2f(0.0, 1.0), vec2f(2.0, 1.0), vec2f(0.0, -1.0));
  var output: VertexOutput;
  output.position = vec4f(positions[index], 0.0, 1.0);
  output.uv = coordinates[index];
  return output;
}

fn encodeExtendedSrgb(linear: vec3f) -> vec3f {
  let value = max(linear, vec3f(0.0));
  let low = 12.92 * value;
  let high = 1.055 * pow(value, vec3f(1.0 / 2.4)) - vec3f(0.055);
  return select(high, low, value <= vec3f(0.0031308));
}

fn hdrGainStops(y: f32, strength: f32) -> f32 {
  let count = i32(params.lutSize);
  if (strength <= 0.0 || count < 2) { return 0.0; }
  let x = clamp(y, 0.0, 1.0) * f32(count - 1);
  let low = i32(floor(x));
  let high = min(low + 1, count - 1);
  return mix(gainLut[low], gainLut[high], x - f32(low)) * strength;
}

@fragment fn fragmentMain(input: VertexOutput) -> @location(0) vec4f {
  let srgbLinear = textureSample(imageTexture, imageSampler, input.uv).rgb;
  let srgbToP3 = mat3x3f(
    vec3f(0.82259287, 0.03319951, 0.01708535),
    vec3f(0.17753395, 0.96678350, 0.07239572),
    vec3f(0.00000000, 0.00000000, 0.91030148));
  var p3 = max(srgbToP3 * srgbLinear, vec3f(0.0));
  let luma = vec3f(0.2289746, 0.6917385, 0.0792869);
  if (params.original > 0.5) { return vec4f(encodeExtendedSrgb(p3), 1.0); }
  p3 *= exp2(params.exposureBias);
  let y = dot(p3, luma);
  let gain = hdrGainStops(y, params.strength);
  var expanded = p3 * exp2(gain);
  let ye = dot(expanded, luma);
  let sat = 1.0 + 0.12 * params.strength * smoothstep(params.expansionStart, 1.0, y);
  expanded = max(vec3f(ye) + (expanded - vec3f(ye)) * sat, vec3f(0.0));
  return vec4f(encodeExtendedSrgb(expanded), 1.0);
}
`;

export async function createHdrRenderer(canvas, onDeviceLost) {
  if (!window.isSecureContext) throw new Error("WebGPU HDR 需要受信任的 HTTPS");
  if (!navigator.gpu) throw new Error("此浏览器未提供 WebGPU");
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) throw new Error("没有可用的 WebGPU 适配器");
  const device = await adapter.requestDevice();
  const context = canvas.getContext("webgpu");
  if (!context) throw new Error("无法创建 WebGPU 画布");

  const configuration = {
    device, format: "rgba16float", colorSpace: "display-p3",
    alphaMode: "opaque", toneMapping: { mode: "extended" },
  };
  // Older Safari rejects an explicit colorSpace on a float target.
  try { context.configure(configuration); }
  catch (_) { delete configuration.colorSpace; context.configure(configuration); }

  const module = device.createShaderModule({ code: SHADER });
  const pipeline = await device.createRenderPipelineAsync({
    layout: "auto",
    vertex: { module, entryPoint: "vertexMain" },
    fragment: { module, entryPoint: "fragmentMain", targets: [{ format: "rgba16float" }] },
    primitive: { topology: "triangle-list" },
  });

  const sampler = device.createSampler({ magFilter: "linear", minFilter: "linear" });
  const uniform = device.createBuffer({
    size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const lut = device.createBuffer({
    size: LUT_SIZE * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });

  let texture = null;
  let bindGroup = null;
  device.lost.then(() => onDeviceLost?.());

  return {
    kind: "hdr",
    outputColorSpace: configuration.colorSpace || "srgb",

    upload(bitmap) {
      texture?.destroy();
      texture = device.createTexture({
        size: [bitmap.width, bitmap.height],
        format: "rgba8unorm-srgb",
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST
             | GPUTextureUsage.RENDER_ATTACHMENT,
      });
      device.queue.copyExternalImageToTexture(
        { source: bitmap }, { texture }, [bitmap.width, bitmap.height]);
      bindGroup = device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
          { binding: 0, resource: sampler },
          { binding: 1, resource: texture.createView() },
          { binding: 2, resource: { buffer: uniform } },
          { binding: 3, resource: { buffer: lut } },
        ],
      });
    },

    draw(table, params) {
      if (!bindGroup) return;
      device.queue.writeBuffer(lut, 0, table);
      device.queue.writeBuffer(uniform, 0, new Float32Array([
        params.strength, params.headroom, params.original ? 1 : 0, params.expansionStart,
        params.areaCoverage, params.exposureBias, LUT_SIZE, 0,
      ]));
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({
        colorAttachments: [{
          view: context.getCurrentTexture().createView(),
          clearValue: { r: 0, g: 0, b: 0, a: 1 }, loadOp: "clear", storeOp: "store",
        }],
      });
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.draw(3);
      pass.end();
      device.queue.submit([encoder.finish()]);
    },

    destroy() { texture?.destroy(); texture = null; bindGroup = null; },
  };
}
