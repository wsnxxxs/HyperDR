import assert from "node:assert/strict";
import fs from "node:fs";

const source = fs.readFileSync(new URL("../../apps/panel/web/js/preview/file-picker.js", import.meta.url), "utf8");
const { pickInputFile } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
const schema = JSON.parse(fs.readFileSync(new URL("../../schema/settings.json", import.meta.url), "utf8"));
const extensions = [...schema.inputs.extensions.raw, ...Object.values(schema.inputs.extensions.raster).flat()];
let options;
let selected;
let clicks = 0;
const args = {
  capabilities: { nativePathInput: true, inputExtensions: extensions },
  dialog: { open: async (value) => { options = value; return "C:\\photos\\photo.JPEG"; } },
  fileInput: { click: () => clicks++ },
  upload: { startNativePath: async (path) => { selected = path; } },
};
await pickInputFile(args);
for (const extension of ["jpg", "jpeg", "png", "heic", "heif", "avif", "cr3", "dng"]) {
  assert.ok(options.filters[0].extensions.includes(extension), extension);
  assert.ok(options.filters.some((filter) => filter.name === `${extension.toUpperCase()} (*.${extension})`
    && filter.extensions.length === 1 && filter.extensions[0] === extension), extension);
}
assert.ok(options.filters.every((filter) => filter.name !== "HyperDR"));
assert.equal(options.multiple, false);
assert.equal(options.directory, false);
assert.equal(selected, "C:\\photos\\photo.JPEG");
assert.equal(clicks, 0);
selected = null;
await pickInputFile({ ...args, dialog: { open: async () => null } });
assert.equal(selected, null);
assert.equal(clicks, 0);
await pickInputFile({ ...args, dialog: undefined });
assert.equal(clicks, 1);
await pickInputFile({ ...args, capabilities: { nativePathInput: false } });
assert.equal(clicks, 2);
console.log("File picker: all supported formats, JPEG aliases, cancellation and browser fallback pass");
