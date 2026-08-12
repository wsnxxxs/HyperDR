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
  areaCoverage: f32, exposureBias: f32, lutSize: f32, vibrance: f32,
  modelEnabled: f32, modelMaxStops: f32, modelStrength: f32, sourceScale: f32,
  sourceExposure: f32, _padding0: f32, _padding1: f32, _padding2: f32,
}
@group(0) @binding(0) var imageSampler: sampler;
@group(0) @binding(1) var imageTexture: texture_2d<f32>;
@group(0) @binding(2) var<uniform> params: Params;
// The exporter's tone curve, uploaded verbatim by the host each frame.
@group(0) @binding(3) var<storage, read> gainLut: array<f32>;
@group(0) @binding(4) var modelGainTexture: texture_2d<f32>;

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

fn modelGainStops(uv: vec2f) -> f32 {
  let dimensions = textureDimensions(modelGainTexture);
  let size = vec2f(dimensions);
  let position = clamp(uv * size - vec2f(0.5), vec2f(0.0), size - vec2f(1.0));
  let low = vec2u(floor(position));
  let high = min(low + vec2u(1u), dimensions - vec2u(1u));
  let lowI = vec2i(i32(low.x), i32(low.y));
  let highI = vec2i(i32(high.x), i32(high.y));
  let fraction = position - vec2f(low);
  let top = mix(
    textureLoad(modelGainTexture, lowI, 0).r,
    textureLoad(modelGainTexture, vec2i(highI.x, lowI.y), 0).r,
    fraction.x);
  let bottom = mix(
    textureLoad(modelGainTexture, vec2i(lowI.x, highI.y), 0).r,
    textureLoad(modelGainTexture, highI, 0).r,
    fraction.x);
  return mix(top, bottom, fraction.y) * params.modelMaxStops * params.modelStrength;
}

@fragment fn fragmentMain(input: VertexOutput) -> @location(0) vec4f {
  // The preview texture holds scene-linear divided by sourceScale, so an HDR
  // input's highlights are only above 1.0 again after this multiply. RAW also
  // carries an automatic scene-exposure anchor; keep it out of the original
  // comparison view but apply it before the look and model paths.
  let sourceLinear = textureSample(imageTexture, imageSampler, input.uv).rgb
    * params.sourceScale;
  let srgbToP3 = mat3x3f(
    vec3f(0.82259287, 0.03319951, 0.01708535),
    vec3f(0.17753395, 0.96678350, 0.07239572),
    vec3f(0.00000000, 0.00000000, 0.91030148));
  var p3 = max(srgbToP3 * sourceLinear, vec3f(0.0));
  let luma = vec3f(0.2289746, 0.6917385, 0.0792869);
  if (params.original > 0.5) { return vec4f(encodeExtendedSrgb(p3), 1.0); }
  p3 *= exp2(params.sourceExposure);
  if (params.modelEnabled > 0.5) {
    let modelExpanded = p3 * exp2(modelGainStops(input.uv));
    return vec4f(encodeExtendedSrgb(modelExpanded), 1.0);
  }
  p3 *= exp2(params.exposureBias);
  var y = dot(p3, luma);
  let sourceSaturation = max(max(abs(p3.r - y), abs(p3.g - y)), abs(p3.b - y)) / max(y, 0.000001);
  let vibranceAmount = params.vibrance * (1.0 - smoothstep(0.15, 1.0, sourceSaturation));
  p3 = max(vec3f(y) + (p3 - vec3f(y)) * (1.0 + vibranceAmount), vec3f(0.0));
  y = dot(p3, luma);
  var gain = hdrGainStops(y, params.strength);
  let diffuseFloor = clamp(params.areaCoverage + 0.20 * params.strength, 0.0, 1.0);
  let highlight = smoothstep(params.expansionStart, 1.0, y);
  let absolute = smoothstep(0.70, 1.50, y * exp2(gain));
  let coverage = diffuseFloor + (1.0 - diffuseFloor) * highlight * absolute;
  gain *= coverage;
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
  const bindGroupLayout = device.createBindGroupLayout({
    entries: [
      { binding: 0, visibility: GPUShaderStage.FRAGMENT,
        sampler: { type: "filtering" } },
      { binding: 1, visibility: GPUShaderStage.FRAGMENT,
        texture: { sampleType: "float" } },
      { binding: 2, visibility: GPUShaderStage.FRAGMENT,
        buffer: { type: "uniform" } },
      { binding: 3, visibility: GPUShaderStage.FRAGMENT,
        buffer: { type: "read-only-storage" } },
      { binding: 4, visibility: GPUShaderStage.FRAGMENT,
        texture: { sampleType: "unfilterable-float" } },
    ],
  });
  const pipeline = await device.createRenderPipelineAsync({
    layout: device.createPipelineLayout({ bindGroupLayouts: [bindGroupLayout] }),
    vertex: { module, entryPoint: "vertexMain" },
    fragment: { module, entryPoint: "fragmentMain", targets: [{ format: "rgba16float" }] },
    primitive: { topology: "triangle-list" },
  });

  const sampler = device.createSampler({ magFilter: "linear", minFilter: "linear" });
  const uniform = device.createBuffer({
    size: 64, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const lut = device.createBuffer({
    size: LUT_SIZE * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });

  let texture = null;
  let modelTexture = device.createTexture({
    size: [1, 1], format: "r32float",
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
  });
  device.queue.writeTexture(
    { texture: modelTexture }, new Float32Array([0]),
    { bytesPerRow: 4 }, [1, 1],
  );
  let bindGroup = null;
  let destroyed = false;
  device.lost.then(() => onDeviceLost?.());

  return {
    kind: "hdr",
    outputColorSpace: configuration.colorSpace || "srgb",

    upload(bitmap) {
      if (destroyed) return;
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
        layout: bindGroupLayout,
        entries: [
          { binding: 0, resource: sampler },
          { binding: 1, resource: texture.createView() },
          { binding: 2, resource: { buffer: uniform } },
          { binding: 3, resource: { buffer: lut } },
          { binding: 4, resource: modelTexture.createView() },
        ],
      });
    },

    uploadGainMap(gain) {
      if (destroyed) return;
      modelTexture.destroy();
      modelTexture = device.createTexture({
        size: [gain.width, gain.height], format: "r32float",
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
      });
      const rowBytes = gain.width * 4;
      const bytesPerRow = Math.ceil(rowBytes / 256) * 256;
      let source = gain.values;
      if (bytesPerRow !== rowBytes) {
        const padded = new Uint8Array(bytesPerRow * gain.height);
        const input = new Uint8Array(
          gain.values.buffer, gain.values.byteOffset, gain.values.byteLength);
        for (let y = 0; y < gain.height; y++) {
          padded.set(input.subarray(y * rowBytes, (y + 1) * rowBytes), y * bytesPerRow);
        }
        source = padded;
      }
      device.queue.writeTexture(
        { texture: modelTexture }, source,
        { bytesPerRow, rowsPerImage: gain.height }, [gain.width, gain.height],
      );
      if (texture) {
        bindGroup = device.createBindGroup({
          layout: bindGroupLayout,
          entries: [
            { binding: 0, resource: sampler },
            { binding: 1, resource: texture.createView() },
            { binding: 2, resource: { buffer: uniform } },
            { binding: 3, resource: { buffer: lut } },
            { binding: 4, resource: modelTexture.createView() },
          ],
        });
      }
    },

    draw(table, params) {
      if (destroyed || !bindGroup) return;
      device.queue.writeBuffer(lut, 0, table);
      device.queue.writeBuffer(uniform, 0, new Float32Array([
        params.strength, params.headroom, params.original ? 1 : 0, params.expansionStart,
        params.areaCoverage, params.exposureBias, LUT_SIZE, params.vibrance,
        params.modelGain ? 1 : 0, params.modelGain?.maxStops || 0,
        params.modelStrength ?? 1, params.sourceScale ?? 1,
        params.sourceExposure ?? 0, 0, 0, 0,
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

    destroy() {
      if (destroyed) return;
      destroyed = true;
      texture?.destroy();
      modelTexture.destroy();
      uniform.destroy();
      lut.destroy();
      texture = null;
      bindGroup = null;
    },
  };
}
