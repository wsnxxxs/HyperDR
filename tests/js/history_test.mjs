import assert from "node:assert/strict";
import fs from "node:fs";

const load = async (path) => import(`data:text/javascript;base64,${
  fs.readFileSync(new URL(path, import.meta.url)).toString("base64")}`);
const { createStore } = await load("../../apps/panel/web/js/core/store.js");
const { createHistory } = await load("../../apps/panel/web/js/settings/history.js");
const store = createStore({ file: { name: "first" }, brightness: 0.6, range: 3 });
const history = createHistory(store, ["brightness", "range"]);
store.set({ brightness: 0.8 }); store.set({ brightness: 1 }); store.set({ brightness: 1.2 });
assert.equal(history.undo(), true);
assert.equal(store.get().brightness, 0.6, "a continuous drag is one undo step");
history.redo(); assert.equal(store.get().brightness, 1.2);
store.set({ brightness: 0.6, range: 2 }); history.flush();
history.undo(); assert.equal(store.get().range, 3, "reset is atomic");
history.undo(); store.set({ range: 1 }); history.flush();
assert.equal(history.redo(), false, "editing after undo drops the old redo branch");
store.set({ uploading: true });
store.set({ file: { name: "second" }, brightness: 0.6 });
store.set({ range: 3, uploading: false });
assert.equal(history.undo(), false, "another photo starts a fresh history");
store.set({ restoring: true, brightness: 1 }); store.set({ restoring: false });
assert.equal(history.undo(), false, "recovery establishes a baseline");
history.dispose();
console.log("Photo history: drag, reset, redo branching, replacement and recovery passed");
