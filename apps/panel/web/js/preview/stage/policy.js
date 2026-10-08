/* Decide preview size and presentation from supplied capabilities without probing a device. */

/* Preview sizes are quantised so a continuous "how wide is the stage right now"
 * does not create a new native frame on every window drag. Three tiers cover
 * phone to desktop, clamped to what the server says it can decode. */
const PREVIEW_TIERS = [960, 1280, 2048];

export function quantizedPreviewTier(ceiling, width, height, devicePixelRatio) {
  const allowed = PREVIEW_TIERS.filter((tier) => tier <= ceiling);
  const list = allowed.length ? allowed : [ceiling];
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const want = Math.max(width, height, 640) * dpr;
  for (const tier of list) if (tier >= want) return tier;
  return list[list.length - 1];
}

export function sdrReasonFor({ encoding, hdrPreview, hdrDisplay, secure, webgpu }) {
  if (["sdr-jpeg", "sdr-tiff"].includes(encoding)) return "hdr.reason.sdrOutput";
  // The preference is a hard veto, not a hint: someone who turned true HDR
  // off wants the SDR path even on hardware that could do better.
  if (!hdrPreview) return "hdr.reason.disabledByPreference";
  if (!hdrDisplay) return "hdr.reason.sdrScreen";
  if (!secure) return "hdr.reason.httpMode";
  if (!webgpu) return "hdr.reason.noWebgpu";
  return "";
}

export function canReuseRenderer(wantsHdr, kind) {
  return (wantsHdr && kind === "hdr") || (!wantsHdr && kind === "sdr-gpu");
}
