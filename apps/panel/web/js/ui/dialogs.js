/** Native dialogs handle Escape, focus trapping and restoring their opener.
 * Dismiss only a gesture that both starts and finishes on the backdrop. */
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
    dialog.addEventListener("close", () => { startedOutside = false; });
  }
}
