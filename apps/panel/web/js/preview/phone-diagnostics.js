import { createHdrRenderer } from "/js/preview/gpu.js";

// Use the same renderer check for an empty-page probe and the photo canvas.
export async function assessPhoneHdr(canvas, onDeviceLost) {
  const result = { secureContext: Boolean(window.isSecureContext), webgpu: Boolean(navigator.gpu), displayHdr: false, hdr: false, reason: "renderer", detail: "" };
  try { result.displayHdr = matchMedia("(dynamic-range: high)").matches; }
  catch (error) { result.detail = String(error.message || error); }
  if (!result.secureContext) result.reason = "insecure";
  else if (!result.webgpu) result.reason = "webgpu";
  else if (!result.displayHdr) result.reason = "display";
  else {
    try {
      const renderer = await createHdrRenderer(canvas, onDeviceLost);
      result.hdr = true; result.reason = "ready";
      result.detail = `HDR 渲染器检测通过 · ${renderer.outputColorSpace || "扩展亮度"}`;
      return { result, renderer };
    } catch (error) { result.detail = String(error.message || error); }
  }
  return { result, renderer: null };
}
