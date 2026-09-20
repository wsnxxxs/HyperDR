import assert from "node:assert/strict";
import fs from "node:fs";
const source = fs.readFileSync(new URL("../../apps/panel/web/js/settings/model-ids.js", import.meta.url));
const { DEFAULT_MODEL_ID, restoredModelId, availableModelIds } = await import(`data:text/javascript;base64,${source.toString("base64")}`);
const models = ["research-cnn-v1", "research-exif-v1"];
assert.equal(DEFAULT_MODEL_ID, models[0]);
for (const saved of [null, {}, { modelId: "production-v3" }, { modelId: "unknown" }]) {
  assert.equal(restoredModelId(saved, models), models[0]);
  assert.equal(restoredModelId(saved, []), models[0]);
}
assert.equal(restoredModelId({modelId: models[1]}, models), models[1]);
assert.equal(restoredModelId({modelId: models[1]}, [models[0]]), models[0]);
assert.deepEqual(availableModelIds({capabilities: {model: {models: [
  {id: "production-v3"}, {id: models[0]}, {id: models[1], available: false}, null,
]}}}), [models[0]]);
assert.deepEqual(availableModelIds({}), []);
console.log("Model recovery: removed models use CNN and supported selections survive");
