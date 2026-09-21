/* One transient status line, shared by every module. */

import { role } from "../core/dom.js";

// An ordinary confirmation only has to be noticed. A warning has to be read:
// these carry the reason a decode was degraded or an export failed, and they
// are longer than the line they replaced, so the same three seconds would let
// the one message the user must not miss be the one they miss.
const VISIBLE_MS = 3000;
const ERROR_VISIBLE_MS = 9000;
// Long enough to cover --duration (200ms) before the popover leaves the top
// layer. Motion-reduced users transition in 0ms and simply wait it out at
// opacity 0, which is not visible either way.
const FADE_OUT_MS = 250;

export function createToast() {
  const node = role("toast");
  let timer = 0;
  let fadeTimer = 0;
  return function toast(message, isError = false) {
    if (!message) return;
    clearTimeout(timer);
    clearTimeout(fadeTimer);
    // Shown before the text is written. A `display: none` popover is not in the
    // accessibility tree, so a message composed while it was closed would never
    // reach the live region -- the toast would be silent as well as invisible.
    if (typeof node.showPopover === "function") {
      try {
        if (!node.matches(":popover-open")) node.showPopover();
      } catch (_) {
        // Older WebViews can expose popover methods without supporting this
        // element's state; the fixed-position fallback remains visible.
        node.removeAttribute("popover");
      }
    }
    node.textContent = message;
    node.classList.toggle("is-error", isError);
    // A transition cannot run from a box that was never laid out, and the
    // popover was `display: none` until a moment ago. One forced reflow gives
    // the fade a start frame; without it the toast snaps in.
    void node.offsetHeight;
    node.classList.add("is-visible");
    timer = setTimeout(() => {
      node.classList.remove("is-visible");
      // Leave the top layer only once the fade has finished, for the same
      // reason: hiding in the same tick cancels the way out.
      fadeTimer = setTimeout(() => {
        try { if (node.matches(":popover-open")) node.hidePopover(); } catch (_) {}
      }, FADE_OUT_MS);
    }, isError ? ERROR_VISIBLE_MS : VISIBLE_MS);
  };
}
