/* Composition root.
 *
 * Every module is a `mount*` function taking the store and whatever collaborators
 * it needs, and returning only what other modules must call. Nothing reaches for
 * a global: this file is the single place that knows the shape of the panel.
 */

import { createStore } from "./core/store.js";
import { api } from "./core/api.js";
import { role, setText } from "./core/dom.js";
import { defaultSettings } from "./settings/schema.js";
import { mountControls } from "./settings/controls.js";
import { createCurve } from "./preview/curve.js";
import { mountStage } from "./preview/stage.js";
import { mountRunner } from "./run/runner.js";
import { createToast } from "./ui/toast.js";
import { mountTheme } from "./ui/theme.js";

const store = createStore({
  ...defaultSettings(),

  // Session: one image at a time; picking another replaces it.
  sessionId: "",
  file: null,
  uploading: false,
  resultUrl: "",

  // Service
  ready: false,
  nativePicker: false,
  transportSecure: false,
  previewMaxEdge: 1280,
  outputSelectionId: "",
  outputDirectory: "",

  // Viewer
  comparing: false,
  hdrOn: true,
  zebra: false,
  histMode: "luma",
});

const toast = createToast();
mountTheme();

const curve = createCurve(store, { onChange: () => stage.redraw() });
const stage = mountStage(store, { curve, toast });

mountControls(store);

mountRunner(store, { toast });

/** Service availability. Failure here is informational: the panel still runs
 *  offline as a look at the interface, it simply cannot convert anything. */
(async function loadServiceState() {
  const dot = role("service-dot");
  const text = role("service-text");
  try {
    const state = await api.state();
    store.set({
      ready: Boolean(state.ready),
      nativePicker: Boolean(state.nativeOutputPicker),
      transportSecure: Boolean(state.transportSecure),
      previewMaxEdge: Number(state.previewMaxEdge) || 1280,
    });
    dot.className = "dot " + (state.ready ? "is-ok" : "is-bad");
    setText(text, state.ready ? "本地处理服务已就绪" : "未找到 HyperDR");
  } catch (_) {
    dot.className = "dot is-warn";
    setText(text, "后端未响应（离线预览）");
  } finally {
    role("service-state").hidden = false;
  }
})();
