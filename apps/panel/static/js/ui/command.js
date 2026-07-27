/* The command line, rendered by the server from the same builder the runner uses.
 *
 * The panel used to assemble a second copy for display and the two had already
 * diverged, so the command shown was not the command run. Nothing here knows
 * what a HyperDR flag looks like.
 */

import { api } from "../core/api.js";
import { debounce, role, setText } from "../core/dom.js";
import { toOptions } from "../settings/schema.js";

export function mountCommand(store) {
  const node = role("command");
  const copyButton = role("command-copy");
  let text = "—";
  let lastKey = "";
  let pendingKey = "";

  async function refresh() {
    const options = toOptions(store.get());
    const key = JSON.stringify(options);
    if (key === lastKey || key === pendingKey) return;
    pendingKey = key;
    try {
      const body = await api.command(options, false);
      text = body.command;
      lastKey = key;
      setText(node, text);
    } catch (_) {
      setText(node, "（后端未响应，无法显示命令）");
    } finally {
      if (pendingKey === key) pendingKey = "";
    }
  }

  const scheduleRefresh = debounce(refresh, 150);

  copyButton.addEventListener("click", async () => {
    const done = (ok) => {
      setText(copyButton, ok ? "已复制" : "复制失败");
      setTimeout(() => setText(copyButton, "复制"), 1400);
    };
    if (navigator.clipboard?.writeText) {
      try { await navigator.clipboard.writeText(text); done(true); }
      catch (_) { done(false); }
      return;
    }
    // Plain-HTTP LAN access has no clipboard API.
    const scratch = document.createElement("textarea");
    scratch.value = text;
    scratch.style.cssText = "position:fixed;opacity:0";
    document.body.append(scratch);
    scratch.select();
    try { done(document.execCommand("copy")); }
    catch (_) { done(false); }
    finally { scratch.remove(); }
  });

  store.subscribe(scheduleRefresh);
  scheduleRefresh();

  /** Called by the runner with the argv the server actually launched. */
  return function show(command) {
    text = command;
    lastKey = "";
    setText(node, command);
  };
}
