/* WebGPU presentation of native linear-Display-P3 float preview planes.
 * Photographic development and gain-map reconstruction happen in C++; this
 * module performs only the display transfer required by the canvas. */

const SHADER = `
struct Params { original: f32, width: f32, height: f32, padding: f32 }
@group(0) @binding(0) var baseTexture: texture_2d<f32>;
@group(0) @binding(1) var hdrTexture: texture_2d<f32>;
@group(0) @binding(2) var<uniform> params: Params;
struct VertexOutput { @builtin(position) position: vec4f, @location(0) uv: vec2f }
@vertex fn vertexMain(@builtin(vertex_index) index: u32) -> VertexOutput {
  var p = array<vec2f, 3>(vec2f(-1,-1), vec2f(3,-1), vec2f(-1,3));
  var u = array<vec2f, 3>(vec2f(0,1), vec2f(2,1), vec2f(0,-1));
  var out: VertexOutput; out.position = vec4f(p[index],0,1); out.uv = u[index]; return out;
}
fn encode(linear: vec3f) -> vec3f {
  let v = max(linear, vec3f(0));
  return select(1.055 * pow(v, vec3f(1.0/2.4)) - vec3f(0.055), 12.92*v,
                v <= vec3f(0.0031308));
}
@fragment fn fragmentMain(input: VertexOutput) -> @location(0) vec4f {
  let xy = vec2i(clamp(input.uv * vec2f(params.width, params.height), vec2f(0),
                       vec2f(params.width-1, params.height-1)));
  let linear = select(textureLoad(hdrTexture, xy, 0).rgb,
                      textureLoad(baseTexture, xy, 0).rgb, params.original > 0.5);
  return vec4f(encode(linear), 1);
}`;

function rgbaPlane(rgb, width, height) {
  const rgba = new Float32Array(width * height * 4);
  for (let s = 0, d = 0; s < rgb.length; s += 3, d += 4) {
    rgba[d] = rgb[s]; rgba[d + 1] = rgb[s + 1]; rgba[d + 2] = rgb[s + 2]; rgba[d + 3] = 1;
  }
  return rgba;
}

function float16ToNumber(bits) {
  const sign = (bits & 0x8000) ? -1 : 1;
  const exponent = (bits >>> 10) & 0x1f;
  const fraction = bits & 0x03ff;
  if (exponent === 0x1f) return fraction ? Number.NaN : sign * Infinity;
  if (exponent === 0) return sign * 2 ** -14 * (fraction / 1024);
  return sign * 2 ** (exponent - 15) * (1 + fraction / 1024);
}

function displayP3Encode(value) {
  const v = Math.max(0, value);
  return v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055;
}

async function verifyExtendedCanvasPixels(device, context, pipeline, uniform, uploadPlane) {
  // getConfiguration() catches ignored dictionary members; this readback catches
  // implementations which report extended mode but clamp the float canvas.  It
  // deliberately runs through the production shader, including the nonlinear
  // Display-P3 transfer expected by an extended canvas.
  const linearProbe = new Float32Array([4.0, 0.18, 0.0]);
  const base = uploadPlane(linearProbe, 1, 1);
  const hdr = uploadPlane(linearProbe, 1, 1);
  const readback = device.createBuffer({
    size: 256,
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
  });
  let mapped = false;
  try {
    const bindGroup = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [
      { binding: 0, resource: base.createView() },
      { binding: 1, resource: hdr.createView() },
      { binding: 2, resource: { buffer: uniform } },
    ] });
    device.queue.writeBuffer(uniform, 0, new Float32Array([0, 1, 1, 0]));
    const encoder = device.createCommandEncoder();
    const canvasTexture = context.getCurrentTexture();
    const pass = encoder.beginRenderPass({ colorAttachments: [{
      view: canvasTexture.createView(),
      clearValue: { r: 0, g: 0, b: 0, a: 1 },
      loadOp: "clear",
      storeOp: "store",
    }] });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.draw(3);
    pass.end();
    encoder.copyTextureToBuffer(
      { texture: canvasTexture },
      { buffer: readback, bytesPerRow: 256, rowsPerImage: 1 },
      [1, 1, 1],
    );
    device.queue.submit([encoder.finish()]);
    await readback.mapAsync(GPUMapMode.READ);
    mapped = true;
    const words = new Uint16Array(readback.getMappedRange(0, 8));
    const actual = [words[0], words[1], words[2], words[3]].map(float16ToNumber);
    const expected = [displayP3Encode(4.0), displayP3Encode(0.18), 0, 1];
    if (actual.some((value, index) => !Number.isFinite(value) ||
        Math.abs(value - expected[index]) > 0.01) || actual[0] <= 1) {
      throw new Error(`WebGPU extended pixel probe failed: ${actual.join(",")}`);
    }
  } finally {
    if (mapped) readback.unmap();
    readback.destroy();
    base.destroy();
    hdr.destroy();
  }
}

export async function createHdrRenderer(canvas, onDeviceLost) {
  if (!window.isSecureContext || !navigator.gpu) throw new Error("WebGPU HDR unavailable");
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) throw new Error("No WebGPU adapter");
  const device = await adapter.requestDevice();
  const context = canvas.getContext("webgpu");
  if (!context) { device.destroy(); throw new Error("No WebGPU canvas context"); }
  const configuration = { device, format: "rgba16float", colorSpace: "display-p3",
    alphaMode: "opaque", toneMapping: { mode: "extended" },
    usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC };
  try {
    context.configure(configuration);
    const actual = context.getConfiguration?.();
    if (actual?.format !== configuration.format ||
        actual?.colorSpace !== configuration.colorSpace ||
        actual?.toneMapping?.mode !== configuration.toneMapping.mode ||
        (actual.usage & GPUTextureUsage.COPY_SRC) === 0) {
      throw new Error("WebGPU canvas did not apply the requested HDR configuration");
    }
  } catch (error) {
    context.unconfigure?.();
    device.destroy();
    throw error;
  }
  const uploadPlane = (values, width, height) => {
    const texture = device.createTexture({ size: [width, height], format: "rgba32float",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    const rgba = rgbaPlane(values, width, height), rowBytes = width * 16;
    const bytesPerRow = Math.ceil(rowBytes / 256) * 256;
    let source = new Uint8Array(rgba.buffer);
    if (bytesPerRow !== rowBytes) {
      const padded = new Uint8Array(bytesPerRow * height);
      for (let y = 0; y < height; y++) padded.set(source.subarray(y*rowBytes,(y+1)*rowBytes), y*bytesPerRow);
      source = padded;
    }
    device.queue.writeTexture({ texture }, source, { bytesPerRow, rowsPerImage: height }, [width, height]);
    return texture;
  };

  let pipeline = null, uniform = null;
  try {
    const module = device.createShaderModule({ code: SHADER });
    pipeline = await device.createRenderPipelineAsync({
      layout: "auto", vertex: { module, entryPoint: "vertexMain" },
      fragment: { module, entryPoint: "fragmentMain", targets: [{ format: "rgba16float" }] },
    });
    uniform = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    await verifyExtendedCanvasPixels(device, context, pipeline, uniform, uploadPlane);
  } catch (error) {
    uniform?.destroy();
    context.unconfigure?.();
    device.destroy();
    throw error;
  }
  let textures = [], bindGroup = null, frame = null, destroyed = false;
  device.lost.then(() => onDeviceLost?.());

  return {
    kind: "hdr", outputColorSpace: configuration.colorSpace,
    upload(next) {
      textures.forEach((t) => t.destroy()); frame = next;
      textures = [uploadPlane(next.base, next.width, next.height), uploadPlane(next.hdr, next.width, next.height)];
      bindGroup = device.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [
        { binding: 0, resource: textures[0].createView() }, { binding: 1, resource: textures[1].createView() },
        { binding: 2, resource: { buffer: uniform } },
      ] });
    },
    uploadGainMap() {},
    draw(_table, params) {
      if (destroyed || !bindGroup) return;
      device.queue.writeBuffer(uniform, 0, new Float32Array([params.original ? 1 : 0, frame.width, frame.height, 0]));
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({ colorAttachments: [{ view: context.getCurrentTexture().createView(),
        clearValue: {r:0,g:0,b:0,a:1}, loadOp:"clear", storeOp:"store" }] });
      pass.setPipeline(pipeline); pass.setBindGroup(0, bindGroup); pass.draw(3); pass.end();
      device.queue.submit([encoder.finish()]);
    },
    destroy() {
      if (destroyed) return;
      destroyed = true; textures.forEach((t) => t.destroy()); uniform.destroy(); bindGroup = null;
      context.unconfigure?.(); device.destroy();
    },
  };
}
