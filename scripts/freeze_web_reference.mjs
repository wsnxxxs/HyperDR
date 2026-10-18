#!/usr/bin/env node
/* Freeze the Web editor's default-value and preview-tier rules for HyperDRKit.
 * Run with --check in tests; --write only when intentionally updating the fixture. */

import { writeFileSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  CONTROLS, ENCODINGS, defaultSettings, referenceSettings,
} from "../apps/panel/web/js/settings/schema.js";
import { quantizedPreviewTier } from "../apps/panel/web/js/preview/stage/policy.js";
import { sampleHdr } from "../apps/panel/web/js/preview/packet.js";
import { t } from "../apps/panel/web/js/i18n/index.js";

const fixture = fileURLToPath(new URL(
  "../apps/apple/Packages/HyperDRKit/Tests/HyperDRKitTests/Fixtures/web-reference.json",
  import.meta.url));
const shaderFixture = fileURLToPath(new URL(
  "../apps/apple/HyperDRPreviewTests/sample-hdr-reference.json", import.meta.url));

const domains = ["scene-referred", "display-referred-sdr", "display-referred-hdr",
  "dual-rendition", "unknown"];
const unadjusted = {
  brightness: 0.25, hdrStrength: 0.8, hdrRange: 3.4, areaCoverage: 0.42, lutStrength: 0.6,
};

function referenceFor(encoding, workflow) {
  const values = referenceSettings(encoding);
  // photo.js keeps these workflow choices when it requests the neutral reference.
  for (const key of ["colorGamut", "outputGamut", "clampSrgb", "rawProfile", "rawLook", "lensCorrection"]) {
    if (key in workflow) values[key] = workflow[key];
  }
  return values;
}

const initial = [];
for (const { id: encoding } of ENCODINGS) {
  for (const sourceDomain of domains) {
    for (const values of [null, unadjusted]) {
      initial.push({ encoding, sourceDomain, unadjusted: values,
        settings: defaultSettings(encoding, sourceDomain, values) });
    }
  }
}

const workflow = {
  ...defaultSettings("adaptive"),
  hevcPreset: "medium", colorGamut: "p3", outputGamut: "rec2020", clampSrgb: true,
  rawProfile: "a".repeat(64), rawProfileName: "Camera DCP",
  rawLook: "b".repeat(64), rawLookName: "Camera look",
  lensCorrection: false, lensProfileName: "Synthetic lens",
  lutId: "c".repeat(64), lutName: "Synthetic LUT", modelId: "research-exif-v1",
};
const reference = ENCODINGS.map(({ id: encoding }) => ({
  encoding, workflow, settings: referenceFor(encoding, workflow),
}));

const previewCases = [
  { ceiling: 2048, width: 320, height: 400, scale: 1 },
  { ceiling: 2048, width: 640, height: 480, scale: 1 },
  { ceiling: 2048, width: 1000, height: 700, scale: 1 },
  { ceiling: 2048, width: 1000, height: 700, scale: 2 },
  { ceiling: 2048, width: 1920, height: 1080, scale: 1 },
  { ceiling: 2048, width: 3000, height: 2000, scale: 1 },
  { ceiling: 1280, width: 1000, height: 700, scale: 1 },
  { ceiling: 1280, width: 1000, height: 700, scale: 2 },
  { ceiling: 960, width: 700, height: 700, scale: 1 },
  { ceiling: 640, width: 1000, height: 700, scale: 1 },
  { ceiling: 0, width: 640, height: 480, scale: 1 },
  { ceiling: 2048, width: 100, height: 100, scale: 3 },
].map((entry) => ({ ...entry,
  edge: quantizedPreviewTier(entry.ceiling, entry.width, entry.height, entry.scale) }));

/* CONTROLS holds formatter functions; name each by what it prints, in the
 * current locale's own units, so the fixture does not depend on the locale. */
function formatName(control) {
  const format = control.format;
  if (!format) return "integer";
  const auto = t("unit.auto");
  const [plus, minus] = [format(1.5), format(-1)];
  if (plus === "+1.50 EV") return "ev";
  if (plus === "+1.50") return "signed";
  if (plus === "1.50") return "fixed2";
  if (plus === "150%") return minus === auto ? "percentOrAuto" : "percent";
  if (plus === t("unit.stops", { value: "1.5" })) return minus === auto ? "stopsOrAuto1" : "stops1";
  throw new Error(`unrecognised format for ${control.key}`);
}

const controls = CONTROLS.map((control) => ({
  key: control.key, kind: control.kind, group: control.group,
  min: control.min ?? null, max: control.max ?? null, step: control.step ?? null,
  default: control.default, format: formatName(control),
  percent: control.unit === "percent", auto: control.auto === true, mask: control.mask,
  label: control.label, help: control.help ?? null,
  choices: control.choices ? control.choices.map(([id]) => id) : null,
}));

function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sorted(value[key])]));
  }
  return value;
}

const document = sorted({
  schema: 1,
  encodings: ENCODINGS.map(({ id, maxRange }) => ({ id, maxRange })),
  controls,
  imageAdjustmentKeys: CONTROLS.map(({ key }) => key),
  domains,
  unadjusted,
  initial,
  reference,
  previewEdge: previewCases,
});
const text = JSON.stringify(document, null, 2) + "\n";

// The Metal pass-1 reference: the shader test builds the same frame and
// compares its reconstruction with `sampleHdr` from the Web editor.
function sampleHdrFixtureText() {
  const width = 7, height = 5;
  const base = Array.from({ length: width * height * 3 },
    (_, index) => ((index * 13) % 41) / 40 - 0.025);
  const fullHdr = base.map((value) => value * 4);
  const gain = [-0.2, 0.15, 0.7, 0.9, 0.4, 1.2];
  const metadata = { gainWidth: 3, gainHeight: 2, gainMin: -0.5, gainMax: 3,
    gainGamma: 1.7, baseOffset: 0.015, alternateOffset: 0.025 };
  const cases = [];
  for (const weight of [0, 0.65, 1]) {
    const frame = { width, height, base, gain,
      metadata: { ...metadata, gainWeight: weight } };
    const values = [];
    const rgb = [0, 0, 0];
    for (let pixel = 0; pixel < width * height; pixel++) {
      sampleHdr(frame, pixel, rgb);
      values.push(...rgb);
    }
    cases.push({ compact: true, original: false, weight, values });
  }
  // v1 full planes: sampleHdr returns the stored HDR plane unchanged.
  const legacy = { width, height, base, hdr: fullHdr };
  const legacyValues = [];
  const rgb = [0, 0, 0];
  for (let pixel = 0; pixel < width * height; pixel++) {
    sampleHdr(legacy, pixel, rgb);
    legacyValues.push(...rgb);
  }
  cases.push({ compact: false, original: false, weight: 1, values: legacyValues });
  return JSON.stringify({ width, height, cases });
}

const shaderText = sampleHdrFixtureText();

if (process.argv.includes("--write")) {
  writeFileSync(fixture, text);
  writeFileSync(shaderFixture, shaderText + "\n");
  console.log(`wrote ${fixture} and ${shaderFixture}`);
} else if (process.argv.includes("--check")) {
  for (const [path, expected] of [[fixture, text], [shaderFixture, shaderText + "\n"]]) {
    let current;
    try { current = readFileSync(path, "utf8"); }
    catch (error) { console.error(`cannot read fixture: ${error.message}`); process.exit(1); }
    if (current !== expected) {
      console.error(`${path} is stale; run node scripts/freeze_web_reference.mjs --write`);
      process.exit(1);
    }
  }
  console.log(`ok: ${initial.length} initial, ${reference.length} reference, ${previewCases.length} preview cases, sampleHdr fixture`);
} else {
  console.log("usage: node scripts/freeze_web_reference.mjs --check|--write");
  process.exit(2);
}
