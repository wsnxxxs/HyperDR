import assert from "node:assert/strict";
import fs from "node:fs";
const { createPreviewScheduler } = await import(`data:text/javascript;base64,${fs.readFileSync(
  new URL("../../apps/panel/web/js/preview/scheduler.js", import.meta.url)).toString("base64")}`);
const tick = () => new Promise(resolve => setTimeout(resolve, 10));
const frames = [];
let complete;
const scheduler = createPreviewScheduler(request => {
  frames.push(request);
  return new Promise(resolve => { complete = resolve; });
}, 0);
scheduler.request(true, 1);
await tick();
assert.equal(frames.length, 1);
for (let i = 2; i < 20; i++) scheduler.request(true, i);
await tick();
assert.equal(frames.length, 1, "only one render runs during continuous input");
scheduler.request(false, 20);
complete();
await tick();
assert.deepEqual(frames[1], { draft: false, requestedAt: 20 }, "release replaces queued drafts");
scheduler.request(true, 21);
scheduler.cancel();
complete();
await tick();
assert.equal(frames.length, 2, "changing photos discards queued work");
console.log("Preview scheduler: coalescing, release refinement and cancellation passed");
