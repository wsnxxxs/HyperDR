import { t } from "../i18n/index.js";
/* Native HYPREV1 packet decoding, shared by the editor and phone viewer. */
export function decodePreview(buffer) {
  const bytes = new Uint8Array(buffer);
  const magic = new TextDecoder().decode(bytes.subarray(0, 8));
  if (magic !== "HYPREV1\n" || bytes.length < 12) {
    throw new Error(t("err.previewData"));
  }
  const jsonSize = new DataView(buffer).getUint32(8, true);
  let metadata;
  try {
    metadata = JSON.parse(new TextDecoder().decode(bytes.subarray(12, 12 + jsonSize)));
  } catch (_) { throw new Error(t("err.previewMeta")); }
  const width = Number(metadata.width), height = Number(metadata.height);
  const count = width * height * 3;
  const offset = 12 + jsonSize;
  if (!Number.isInteger(width) || width <= 0 || !Number.isInteger(height) || height <= 0
      || offset + count * 8 !== bytes.length) {
    throw new Error(t("err.previewPixels"));
  }
  // The JSON header need not be aligned; copies give each float plane aligned storage.
  const copyPlane = (start) => {
    const copy = bytes.slice(start, start + count * 4);
    return new Float32Array(copy.buffer, copy.byteOffset, count);
  };
  return {
    width, height, metadata,
    base: copyPlane(offset), hdr: copyPlane(offset + count * 4),
  };
}
