/* Tiny DOM helpers.
 *
 * Elements are addressed by `data-role`, never by id, and looked up with a
 * literal string: scripts/check_panel_roles.py reads these calls and fails the
 * build when a role a module asks for is not in the markup (or the other way
 * round). A template-literal role name is therefore a bug that ships.
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

/** Read a `<color>` custom property resolved by getComputedStyle, as numeric
 *  channels for ImageData work plus the original text for canvas fillStyle.
 *  Handles the serializations browsers actually return: hex, rgb()/rgba(),
 *  and color(srgb …). */
export function readColor(name) {
  const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const hex = /^#([0-9a-f]{6})(?:[0-9a-f]{2})?$/i.exec(raw);
  if (hex) {
    return {
      r: parseInt(hex[1].slice(0, 2), 16),
      g: parseInt(hex[1].slice(2, 4), 16),
      b: parseInt(hex[1].slice(4, 6), 16),
      css: raw,
    };
  }
  const rgb = /^rgba?\(\s*(\d+)[,\s]+(\d+)[,\s]+(\d+)/i.exec(raw);
  if (rgb) return { r: +rgb[1], g: +rgb[2], b: +rgb[3], css: raw };
  const srgb = /^color\(srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/i.exec(raw);
  if (srgb) {
    return {
      r: Math.round(+srgb[1] * 255),
      g: Math.round(+srgb[2] * 255),
      b: Math.round(+srgb[3] * 255),
      css: raw,
    };
  }
  return { r: 0, g: 0, b: 0, css: raw || "#000000" };
}
