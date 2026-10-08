/* Select, replace and report the HDR / SDR GPU / CPU presentation path. */

import { store } from "../../core/store.js";
import { prefs } from "../../ui/prefs-schema.js";
import { setText } from "../../core/dom.js";
import { t, onLocaleChange } from "../../i18n/index.js";
import { effectiveOutputGamut } from "../../settings/schema.js";
import { renderSdr } from "../cpu.js";
import { createHdrRenderer } from "../gpu.js";
import { createSdrGpuRenderer } from "../sdr-gpu.js";
import { sdrReasonFor, canReuseRenderer } from "./policy.js";


export function createRendering(ctx) {
  const { image, detail, analysis, toast, actions } = ctx;
  const { stage, hdrStatus, hdrCanvas } = ctx.dom;

  const { hdrDisplayQuery } = ctx;

  /* ── capability reporting ─────────────────────────────────────────── */


  function setCapability(key, ok, params) {
    ctx.lastCapability = { key, ok, params };
    const state = store.get();
    const format = state.encoding === "sdr-tiff" ? "TIFF" : "JPEG";
    const gamut = effectiveOutputGamut(state.encoding, state.outputGamut) === "p3" ? "Display P3" : "sRGB";
    const message = ["sdr-jpeg", "sdr-tiff"].includes(state.encoding) ? t("hdr.sdrOutput", { format, gamut })
      : t(key, params?.reasonKey ? { ...params, reason: t(params.reasonKey) } : params);
    const domain = ctx.sourceDomainLabel ? t(ctx.sourceDomainLabel) : "";
    setText(hdrStatus, domain ? `${domain} · ${message}` : message);
    hdrStatus.classList.toggle("is-ok", Boolean(ok));
    hdrStatus.hidden = !Boolean(image.source);
    stage.dataset.previewMode = ctx.renderer?.kind || "uninitialized";
  }

  function reportInitialCapability() {
    if (!prefs.get().hdrPreview) setCapability("hdr.disabled", false);
    else if (!hdrDisplayQuery.matches) setCapability("hdr.sdrScreen", false);
    else if (!window.isSecureContext) setCapability("hdr.httpMode", false);
    else if (!navigator.gpu) setCapability("hdr.noWebgpu", false);
    else setCapability("hdr.waiting", false);
  }
  /* ── rendering ────────────────────────────────────────────────────── */

  function draw() {
    ctx.animationFrame = 0;
    if (!image.source) return;
    if (ctx.renderer) {
      // `originalCanvas` owns the comparison view; keep the GPU renderer on
      // the current effect frame even while that layer is temporarily over it.
      renderer.draw(null, { original: false });
    } else {
      renderSdr(ctx.dom.sdrCanvas, { frame: image.frame, original: false });
    }
  }

  function schedule() {
    if (!image.source) return;
    if (ctx.animationFrame) cancelAnimationFrame(ctx.animationFrame);
    ctx.animationFrame = requestAnimationFrame(draw);
  }

  function showCanvas(mode) {
    hdrCanvas.hidden = mode !== "hdr" || actions.view.showingOriginal();
    ctx.dom.sdrCanvas.hidden = mode !== "sdr" || actions.view.showingOriginal();
  }

  function prepareHdrCanvas() {
    // Let the visible stage establish its clip before WebGPU creates the
    // swap chain. This matters on Chromium when the canvas can become a
    // DirectComposition overlay.
    hdrCanvas.hidden = false;
    ctx.dom.sdrCanvas.hidden = true;
    return new Promise((resolve) => requestAnimationFrame(resolve));
  }

  /** Why the true-HDR path is unavailable, or "" when it is available.
   *
   *  One function so the branch that picks the renderer, the branch that reuses
   *  it, and the status line can never disagree about the reason -- the
   *  diagnostics group reports this string, and "SDR preview" with no cause was
   *  the least useful thing it could say.
   */
  function sdrReason() {
    return sdrReasonFor({ encoding: store.get().encoding,
      hdrPreview: prefs.get().hdrPreview, hdrDisplay: hdrDisplayQuery.matches,
      secure: window.isSecureContext, webgpu: Boolean(navigator.gpu) });
  }

  const canUseHdrRenderer = () => sdrReason() === "";

  function chooseSdrRenderer(reason, epoch = ctx.rendererGeneration, forceCpu = false) {
    if (!ctx.isCurrentRenderer(epoch) || !image.frame) return;
    ctx.renderer?.destroy();
    ctx.renderer = null;
    try {
      if (forceCpu) throw new Error("WebGL context lost");
      let created = null;
      created = createSdrGpuRenderer(ctx.dom.sdrCanvas, () => {
        if (ctx.isCurrentRenderer(epoch) && ctx.renderer === created) {
          chooseSdrRenderer("hdr.reason.sdrDeviceLost", epoch, true);
        }
      });
      ctx.renderer = created;
      ctx.renderer.upload(image.frame);
      showCanvas("sdr");
      setCapability("hdr.sdrPreviewWhy", false, { reasonKey: reason });
    } catch (error) {
      ctx.renderer = null;
      // A canvas that has successfully created a WebGL context cannot later
      // switch to 2D. Replace it before entering the last-resort CPU path if
      // WebGL setup failed after context creation.
      const replacement = ctx.dom.sdrCanvas.cloneNode(false);
      replacement.width = ctx.dom.sdrCanvas.width;
      replacement.height = ctx.dom.sdrCanvas.height;
      ctx.dom.sdrCanvas.replaceWith(replacement);
      ctx.dom.sdrCanvas = replacement;
      showCanvas("sdr");
      setCapability("hdr.sdrCompatWhy", false, { reasonKey: reason });
    }
    actions.view.syncView();
    schedule();
  }

  async function chooseRenderer(epoch = ctx.invalidateRenderer()) {
    if (!ctx.isCurrentRenderer(epoch) || !image.frame) return;

    // Look changes replace the uploaded planes, not the display technology.
    // Reusing the live renderer avoids tearing down the visible swap chain and
    // also means the HDR capability probe runs only when the renderer really
    // has to be created.  Device/display capability changes still fall through
    // to the normal destroy-and-select path below.
    const wantsHdr = canUseHdrRenderer();
    if (canReuseRenderer(wantsHdr, ctx.renderer?.kind)) {
      ctx.renderer.upload(image.frame);
      showCanvas(wantsHdr ? "hdr" : "sdr");
      if (wantsHdr) {
        const gamut = ctx.renderer.outputColorSpace === "display-p3"
          ? "Display P3" : t("hdr.gamutExtendedSrgb");
        setCapability("hdr.true", true, { gamut });
      } else {
        const reason = sdrReason();
        if (reason) setCapability("hdr.sdrPreviewWhy", false, { reasonKey: reason });
        else setCapability("hdr.sdrPreview", false);
      }
      actions.view.syncView();
      schedule();
      return;
    }

    ctx.renderer?.destroy();
    ctx.renderer = null;

    const blocked = sdrReason();
    if (blocked) {
      chooseSdrRenderer(blocked, epoch);
    } else {
      let created = null;
      setCapability("hdr.verifying", false);
      try {
        await prepareHdrCanvas();
        if (!ctx.isCurrentRenderer(epoch) || !image.frame) return;
        created = await createHdrRenderer(hdrCanvas, () => {
          if (ctx.isCurrentRenderer(epoch) && ctx.renderer === created) {
            chooseSdrRenderer("hdr.reason.deviceLost", epoch);
          }
        });
        if (!ctx.isCurrentRenderer(epoch) || !image.frame) { created.destroy(); return; }
        ctx.renderer = created;
        ctx.renderer.upload(image.frame);
        showCanvas("hdr");
        const gamut = ctx.renderer.outputColorSpace === "display-p3"
          ? "Display P3" : t("hdr.gamutExtendedSrgb");
        setCapability("hdr.true", true, { gamut });
      } catch (error) {
        created?.destroy();
        if (!ctx.isCurrentRenderer(epoch)) return;
        const detail = error?.message ? `: ${error.message}` : "";
        console.error("HyperDR HDR renderer initialization failed", error);
        chooseSdrRenderer(t("hdr.reason.initFailed", { detail }), epoch);
      }
    }
    if (!ctx.isCurrentRenderer(epoch)) return;
    actions.view.syncView();
    schedule();
  }
  function mountReactions() {
    store.watchAny(["encoding", "outputGamut"], () => {
      if (ctx.lastCapability) setCapability(ctx.lastCapability.key, ctx.lastCapability.ok, ctx.lastCapability.params);
    });
  }

  function mountDisplay() {
    hdrDisplayQuery.addEventListener?.("change", () => {
      reportInitialCapability();
      if (image.source) chooseRenderer();
    });
  }

  function mountPreference() {
    /* Preference reactions.
     *
     * Turning true HDR off has to re-pick the renderer, not merely relabel the
     * status line: the WebGPU context is chosen once per image and would keep
     * painting until the next load. Narrowing the resolution cap re-requests the
     * frame at the new tier, which is what `load` does when the tier moves. */
    prefs.watch("hdrPreview", () => {
      reportInitialCapability();
      if (image.source) chooseRenderer();
    });
  }

  function mountLocale() {
    /* Nothing here re-renders on its own, so a language change re-emits the
     * strings this module wrote imperatively. `lastCapability` is kept as a key
     * plus parameters precisely so this does not have to re-probe the GPU. */
    onLocaleChange(() => {
      if (ctx.lastCapability) {
        setCapability(ctx.lastCapability.key, ctx.lastCapability.ok, ctx.lastCapability.params);
      }
    });
  }


  return { setCapability, reportInitialCapability, draw, schedule, showCanvas, prepareHdrCanvas, sdrReason, canUseHdrRenderer, chooseSdrRenderer, chooseRenderer, mountReactions, mountDisplay, mountPreference, mountLocale };
}
