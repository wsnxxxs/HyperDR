/* Decide preview presentation from supplied capabilities without probing a device. */

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
