/* WebGL2 SDR preview renderer.
 *
 * The SDR fallback used to walk every pixel in JavaScript on every slider
 * frame. That is tolerable on a desktop CPU and visibly stalls Safari on an
 * iPhone. WebGL2 is available in the same plain-HTTP environments where
 * WebGPU is unavailable, so it is the right accelerated fallback.
 */

import { LUT_SIZE } from "./curve.js";

const VERTEX = `#version 300 es
in vec2 position;
out vec2 uv;
void main() {
  gl_Position = vec4(position, 0.0, 1.0);
  uv = vec2((position.x + 1.0) * 0.5, (1.0 - position.y) * 0.5);
}`;

const FRAGMENT = `#version 300 es
precision highp float;
precision highp sampler2D;

uniform sampler2D imageTexture;
uniform sampler2D gainTexture;
uniform float strength;
uniform float exposureBias;
uniform float expansionStart;
uniform float areaCoverage;
uniform float vibrance;
uniform float original;
in vec2 uv;
out vec4 color;

const vec3 luma = vec3(0.2126, 0.7152, 0.0722);

vec3 encodeSrgb(vec3 linear) {
  vec3 value = max(linear, vec3(0.0));
  vec3 low = 12.92 * value;
  vec3 high = 1.055 * pow(value, vec3(1.0 / 2.4)) - vec3(0.055);
  return mix(high, low, lessThanEqual(value, vec3(0.0031308)));
}

float gainStops(float y) {
  if (strength <= 0.0) return 0.0;
  float x = clamp(y, 0.0, 1.0) * float(${LUT_SIZE - 1});
  int low = int(floor(x));
  int high = min(low + 1, ${LUT_SIZE - 1});
  float a = texelFetch(gainTexture, ivec2(low, 0), 0).r;
  float b = texelFetch(gainTexture, ivec2(high, 0), 0).r;
  return mix(a, b, x - float(low)) * strength;
}

float shoulder(float value) {
  const float knee = 0.8;
  if (value <= knee) return value;
  return knee + (1.0 - knee) *
    (1.0 - exp(-(value - knee) / (1.0 - knee)));
}

void main() {
  vec3 linear = texture(imageTexture, uv).rgb;
  if (original > 0.5) {
    color = vec4(encodeSrgb(linear), 1.0);
    return;
  }
  linear *= exp2(exposureBias);
  float y = dot(linear, luma);
  float sourceSaturation = max(max(abs(linear.r - y), abs(linear.g - y)), abs(linear.b - y))
    / max(y, 0.000001);
  float vibranceAmount = vibrance *
    (1.0 - smoothstep(0.15, 1.0, sourceSaturation));
  linear = max(vec3(y) + (linear - vec3(y)) * (1.0 + vibranceAmount), vec3(0.0));
  y = dot(linear, luma);
  float gain = gainStops(y);
  float diffuseFloor = clamp(areaCoverage + 0.20 * strength, 0.0, 1.0);
  float highlight = smoothstep(expansionStart, 1.0, y);
  float absolute = smoothstep(0.70, 1.50, y * exp2(gain));
  float coverage = diffuseFloor + (1.0 - diffuseFloor) * highlight * absolute;
  vec3 expanded = linear * exp2(gain * coverage);
  float ye = dot(expanded, luma);
  float saturation = 1.0 + 0.12 * strength * smoothstep(expansionStart, 1.0, y);
  expanded = max(vec3(ye) + (expanded - vec3(ye)) * saturation, vec3(0.0));
  color = vec4(encodeSrgb(vec3(
    shoulder(expanded.r), shoulder(expanded.g), shoulder(expanded.b))), 1.0);
}`;

function compile(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const message = gl.getShaderInfoLog(shader) || "着色器编译失败";
    gl.deleteShader(shader);
    throw new Error(message);
  }
  return shader;
}

export function createSdrGpuRenderer(canvas, onContextLost) {
  const handleContextLost = (event) => {
    event.preventDefault();
    onContextLost?.();
  };
  canvas.addEventListener("webglcontextlost", handleContextLost, { once: true });
  const gl = canvas.getContext("webgl2", {
    alpha: false, antialias: false, depth: false, stencil: false,
    powerPreference: "high-performance",
  });
  if (!gl) throw new Error("此浏览器未提供 WebGL2");

  const program = gl.createProgram();
  const vertex = compile(gl, gl.VERTEX_SHADER, VERTEX);
  const fragment = compile(gl, gl.FRAGMENT_SHADER, FRAGMENT);
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);
  gl.deleteShader(vertex);
  gl.deleteShader(fragment);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(program) || "预览管线链接失败");
  }

  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
    -1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1,
  ]), gl.STATIC_DRAW);

  const imageTexture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, imageTexture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

  const gainTexture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, gainTexture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texImage2D(
    gl.TEXTURE_2D, 0, gl.R32F, LUT_SIZE, 1, 0, gl.RED, gl.FLOAT,
    new Float32Array(LUT_SIZE));

  const locations = {
    position: gl.getAttribLocation(program, "position"),
    imageTexture: gl.getUniformLocation(program, "imageTexture"),
    gainTexture: gl.getUniformLocation(program, "gainTexture"),
    strength: gl.getUniformLocation(program, "strength"),
    exposureBias: gl.getUniformLocation(program, "exposureBias"),
    expansionStart: gl.getUniformLocation(program, "expansionStart"),
    areaCoverage: gl.getUniformLocation(program, "areaCoverage"),
    vibrance: gl.getUniformLocation(program, "vibrance"),
    original: gl.getUniformLocation(program, "original"),
  };

  gl.useProgram(program);
  gl.enableVertexAttribArray(locations.position);
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.vertexAttribPointer(locations.position, 2, gl.FLOAT, false, 0, 0);
  gl.uniform1i(locations.imageTexture, 0);
  gl.uniform1i(locations.gainTexture, 1);

  return {
    kind: "sdr-gpu",

    upload(bitmap) {
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, imageTexture);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      gl.texImage2D(
        gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
      gl.viewport(0, 0, canvas.width, canvas.height);
    },

    draw(table, params) {
      gl.useProgram(program);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, imageTexture);
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, gainTexture);
      gl.texSubImage2D(
        gl.TEXTURE_2D, 0, 0, 0, LUT_SIZE, 1, gl.RED, gl.FLOAT, table);
      gl.uniform1f(locations.strength, params.strength);
      gl.uniform1f(locations.exposureBias, params.exposureBias);
      gl.uniform1f(locations.expansionStart, params.expansionStart);
      gl.uniform1f(locations.areaCoverage, params.areaCoverage);
      gl.uniform1f(locations.vibrance, params.vibrance);
      gl.uniform1f(locations.original, params.original ? 1 : 0);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    },

    destroy() {
      canvas.removeEventListener("webglcontextlost", handleContextLost);
      gl.deleteTexture(imageTexture);
      gl.deleteTexture(gainTexture);
      gl.deleteBuffer(buffer);
      gl.deleteProgram(program);
    },
  };
}
