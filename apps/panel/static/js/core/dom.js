/* Tiny DOM helpers.
 *
 * Elements are addressed by `data-role`, never by id. The old panel used ids
 * plus inline `onclick=` attributes, which meant the markup named twenty global
 * functions and no module could be loaded twice or tested in isolation. A role
 * is a contract between one module and its own fragment of markup.
 */

export const role = (name, scope = document) =>
  scope.querySelector(`[data-role="${name}"]`);

export const roleAll = (name, scope = document) =>
  Array.from(scope.querySelectorAll(`[data-role="${name}"]`));

/** Create an element in one call: el("button", {class: "x"}, "label"). */
export function el(tag, attributes = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes)) {
    if (value == null || value === false) continue;
    if (key === "class") node.className = value;
    else if (key === "dataset") Object.assign(node.dataset, value);
    else if (key.startsWith("on")) node.addEventListener(key.slice(2).toLowerCase(), value);
    else if (value === true) node.setAttribute(key, "");
    else node.setAttribute(key, String(value));
  }
  for (const child of children.flat()) {
    if (child == null) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

export function setText(node, text) {
  if (node && node.textContent !== text) node.textContent = text;
}

/** Reflect a boolean onto both the class and the ARIA state of a toggle. */
export function setPressed(node, on, { aria = "aria-pressed" } = {}) {
  if (!node) return;
  node.classList.toggle("is-on", on);
  node.setAttribute(aria, String(on));
}

/** Trailing-edge debounce; returns a function with a `.cancel()`. */
export function debounce(fn, delay) {
  let timer = 0;
  const wrapped = (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), delay);
  };
  wrapped.cancel = () => clearTimeout(timer);
  return wrapped;
}

export const clamp = (value, low, high) => Math.min(high, Math.max(low, value));
