import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

// Exercise return paths and backdrop gestures; native Escape/focus containment
// are also checked in the browser, rather than reimplemented in this fixture.
const source = fs.readFileSync(new URL("../../apps/panel/web/js/ui/dialogs.js", import.meta.url), "utf8")
  .replace(/^export /gm, "");
const document = { activeElement: null, querySelectorAll: () => dialogs };
function button(parent = null) {
  return { isConnected: true, attributes: {}, disabled: false,
    closest: () => parent?.open ? parent : null,
    setAttribute(key, value) { this.attributes[key] = value; },
    focus() { document.activeElement = this; } };
}
function dialog() {
  const close = button(), handlers = {};
  return { open: false, dataset: {},
    addEventListener(type, handler) { handlers[type] = handler; },
    showModal() { this.open = true; },
    close() { this.open = false; handlers.close(); },
    querySelector: () => close,
    getBoundingClientRect: () => ({ left: 100, right: 940, top: 60, bottom: 660 }),
    pointer(type, x, y) { handlers[type]({ target: this, clientX: x, clientY: y }); } };
}
const settings = dialog(), phone = dialog(), library = dialog();
const dialogs = [settings, phone, library];
const context = vm.createContext({ document });
vm.runInContext(source, context);
context.mountDialogs();
const { openDialog } = context;

const settingsEntry = button(), phoneEntry = button(settings);
settingsEntry.focus();
openDialog(settings);
phoneEntry.focus();
openDialog(phone);
assert.equal(settings.dataset.dialogCovered, "true");
assert.equal(phone.dataset.dialogNested, "true");
assert.equal(openDialog(phone), false, "reopening the active view preserves its origin");
phone.close();
assert.equal(settings.open, true, "return keeps the source view alive");
assert.equal(settings.dataset.dialogCovered, undefined);
assert.equal(document.activeElement, phoneEntry);
settings.close();
assert.equal(document.activeElement, settingsEntry);
assert.equal(settingsEntry.attributes["aria-expanded"], "false");

// Both library entry points restore the actual source, even when one forwards
// its click to a shared handler.
for (const entry of [button(), button()]) {
  entry.focus();
  openDialog(library);
  library.pointer("pointerdown", 120, 90);
  library.pointer("click", 90, 90);
  assert.equal(library.open, true, "dragging out of content must not dismiss");
  library.pointer("pointerdown", 90, 90);
  library.pointer("click", 120, 90);
  assert.equal(library.open, true, "a gesture ending inside must not dismiss");
  library.pointer("pointerdown", 90, 90);
  library.pointer("click", 90, 90);
  assert.equal(library.open, false);
  assert.equal(document.activeElement, entry);
}
console.log("Dialog navigation: source views, focus restoration and backdrop gestures passed");
