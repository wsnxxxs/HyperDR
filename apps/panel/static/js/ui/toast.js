/* One transient status line, shared by every module. */

import { role } from "../core/dom.js";

// An ordinary confirmation only has to be noticed. A warning has to be read:
// these carry the reason a decode was degraded or an export failed, and they are
// longer than the line they replaced, so the same three seconds would let the
// one message the user must not miss be the one they miss.
const VISIBLE_MS = 3000;
const ERROR_VISIBLE_MS = 9000;

export function createToast() {
  const node = role("toast");
  let timer = 0;
  return function toast(message, isError = false) {
    if (!message) return;
    clearTimeout(timer);
    node.textContent = message;
    node.classList.toggle("is-error", isError);
    node.classList.add("is-visible");
    timer = setTimeout(() => node.classList.remove("is-visible"),
                       isError ? ERROR_VISIBLE_MS : VISIBLE_MS);
  };
}
