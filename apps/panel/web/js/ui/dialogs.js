const origins = new WeakMap();

/** Keep the source view in place so every dismissal returns to the same context. */
export function openDialog(dialog, trigger = document.activeElement) {
  if (dialog.open) return false;
  const parent = trigger?.closest("dialog[open]");
  origins.set(dialog, { trigger, parent });
  dialog.dataset.dialogNested = String(Boolean(parent));
  if (parent) parent.dataset.dialogCovered = "true";
  trigger?.setAttribute("aria-haspopup", "dialog");
  trigger?.setAttribute("aria-expanded", "true");
  dialog.showModal();
  dialog.querySelector(".dialog-head .icon-button")?.focus({ preventScroll: true });
  return true;
}

/** Native dialogs handle Escape and focus containment. All close routes share
 * the same return behavior, including clicks that start and end on the backdrop. */
export function mountDialogs() {
  for (const dialog of document.querySelectorAll("dialog.app-dialog")) {
    let startedOutside = false;
    const outside = (event) => {
      const bounds = dialog.getBoundingClientRect();
      return event.target === dialog && (event.clientX < bounds.left || event.clientX > bounds.right
        || event.clientY < bounds.top || event.clientY > bounds.bottom);
    };
    dialog.addEventListener("pointerdown", (event) => { startedOutside = outside(event); });
    dialog.addEventListener("pointercancel", () => { startedOutside = false; });
    dialog.addEventListener("click", (event) => {
      if (startedOutside && outside(event)) dialog.close();
      startedOutside = false;
    });
    dialog.addEventListener("close", () => {
      startedOutside = false;
      if (dialog.open) return;
      const origin = origins.get(dialog);
      origins.delete(dialog);
      if (!origin) return;
      const { trigger, parent } = origin;
      if (parent) delete parent.dataset.dialogCovered;
      trigger?.setAttribute("aria-expanded", "false");
      if (trigger?.isConnected && !trigger.disabled) trigger.focus({ preventScroll: true });
    });
  }
}
