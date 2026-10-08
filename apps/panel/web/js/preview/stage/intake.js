/* Accept picker, native drop, browser drop and clipboard photos through the uploader. */

import { store } from "../../core/store.js";
import { setText } from "../../core/dom.js";
import { t, onLocaleChange } from "../../i18n/index.js";
import { createUploader } from "../session.js";
import { pickInputFile } from "../file-picker.js";


export function createIntake(ctx) {
  const { image, detail, analysis, toast, actions } = ctx;
  const { stage, selectButton, fileInput, supportHint, uploadCancel, progressBar, progressText, uploadOverlayText, uploadOverlay, emptyTitle } = ctx.dom;

  const upload = createUploader({
    onProgress: (fraction) => {
      const percent = Math.round(fraction * 100);
      progressBar.style.width = `${percent}%`;
      const uploading = t("stage.uploading", { percent });
      setText(progressText, fraction > 0 && fraction < 1 ? uploading : "");
      setText(uploadOverlayText, uploading);
    },
    onReady: actions.photo.preparePhoto,
    onError: (message, { preserveCurrent, cancelled } = {}) => {
      // A user-aborted upload is a confirmation, not a failure: keep the
      // current image (or the plain empty state) and say so quietly.
      if (cancelled) {
        if (!preserveCurrent) actions.photo.clear();
        toast(message);
        return;
      }
      if (!preserveCurrent) actions.photo.clear(message);
      toast(message, true);
    },
  });

  /* ── input wiring ─────────────────────────────────────────────────── */

  const canReplace = () => {
    const state = store.get();
    return !state.restoring && !state.starting && !state.uploading && !state.optimizing && !state.jobId;
  };
  const nativeDropQueueKey = "__HYPERDR_NATIVE_FILE_DROPS__";
  const consumeNativeDrop = () => {
    const queued = globalThis[nativeDropQueueKey];
    const capabilities = store.get().capabilities;
    // Keep a native drop queued until the boot capability request completes;
    // otherwise a very quick drop after launch would be mistaken for a browser
    // page that does not support the desktop bridge.
    if (!Array.isArray(queued) || !capabilities || store.get().restoring) return;
    globalThis[nativeDropQueueKey] = [];
    if (!canReplace() || !capabilities.nativePathInput) return;
    const path = queued.find((value) => typeof value === "string" && value);
    if (path) upload.startNativePath(path);
  };
  // Rust queues before dispatching, so this also handles a drop that arrived
  // during panel initialization.
  function mountNativeDrop() {
    window.addEventListener("hyperdr:native-file-drop", consumeNativeDrop);
    store.watchAny(["capabilities", "restoring"], consumeNativeDrop);
    consumeNativeDrop();
  }

  /* What the picker offers and what the hint promises both come from the
   * converter's own extension table, served in /api/state. The markup used to
   * carry a hand-written accept list -- the fifth copy of that list in the
   * project, and the one most likely to be forgotten. */
  const describeSupport = () => {
    const capabilities = store.get().capabilities;
    const extensions = capabilities?.inputExtensions;
    if (!Array.isArray(extensions) || !extensions.length) return;
    fileInput.accept = extensions.join(",");
    setText(supportHint, t("stage.support"));
    supportHint.title = extensions.join(" ");
  };
  function mountSupport() {
    store.watch("capabilities", describeSupport);
    describeSupport();
  }

  /* One image per session, so a multiple selection is not an error -- but it is
   * not what the user asked for either, and silently keeping the first of five
   * files reads as the panel losing four of them. */
  const startUpload = (files) => {
    const list = Array.from(files || []);
    if (!list.length) return false;
    if (list.length > 1) {
      toast(t("err.oneFile", { name: list[0].name }));
    }
    upload.start(list);
    return true;
  };

  let pickingFile = false;
  const openPicker = async () => {
    if (!canReplace() || pickingFile) return;
    pickingFile = true;
    try {
      await pickInputFile({ capabilities: store.get().capabilities,
        dialog: window.__TAURI__?.dialog, fileInput, upload });
    } catch (error) {
      toast(error.message || t("err.nativeInput"), true);
    } finally {
      pickingFile = false;
    }
  };
  function mountDrop() {
    for (const type of ["dragover", "dragenter"]) {
      stage.addEventListener(type, (event) => {
        event.preventDefault();
        stage.classList.add("is-drop-target");
      });
    }
    stage.addEventListener("dragleave", (event) => {
      if (!stage.contains(event.relatedTarget)) stage.classList.remove("is-drop-target");
    });
    stage.addEventListener("drop", (event) => {
      event.preventDefault();
      stage.classList.remove("is-drop-target");
      if (!canReplace()) return;
      // A folder, a link or a text selection arrives with no files at all. Doing
      // nothing at that point looks like the drop was missed rather than refused.
      if (!startUpload(event.dataTransfer.files)) {
        toast(t("err.singleFileDrop"), true);
      }
    });

    /* Pasting is the sibling of dropping and was simply missing: a screenshot on
     * the clipboard had to be saved to disk first. Ignored while a text field has
     * focus, so pasting into an input still pastes text. */
    document.addEventListener("paste", (event) => {
      const target = event.target;
      if (target instanceof Element
          && target.closest("input, textarea, [contenteditable]")) return;
      const files = Array.from(event.clipboardData?.files || []);
      if (!files.length || !canReplace()) return;
      event.preventDefault();
      startUpload(files);
    });
  }

  function mountReactions() {
    store.watchAny(["uploading"], (state) => {
      stage.classList.toggle("is-uploading", state.uploading);
      stage.setAttribute("aria-busy", String(state.uploading));
      selectButton.disabled = state.uploading;
      uploadOverlay.hidden = !state.uploading;
      // The first photo arrives on the empty card, whose headline would
      // otherwise keep inviting a drop while the bar fills underneath it.
      if (state.uploading && !image.source) setText(emptyTitle, t("stage.reading"));
    });
    store.watch("uploadProgress", (fraction) => {
      const percent = Math.round(fraction * 100);
      progressBar.style.width = `${percent}%`;
      setText(uploadOverlayText, t("stage.uploading", { percent }));
    });
  }

  function mountLocale() {
    onLocaleChange(() => {
      setText(supportHint, t("stage.support"));
    });
  }

  function mountPicker() {
    selectButton.addEventListener("click", openPicker);
    fileInput.addEventListener("change", (event) => {
      startUpload(event.target.files);
      fileInput.value = "";
    });
    uploadCancel.addEventListener("click", (event) => {
      event.stopPropagation();
      upload.abort();
    });
  }


  return { canReplace, consumeNativeDrop, describeSupport, startUpload, openPicker, mountNativeDrop, mountSupport, mountPicker, mountDrop, mountReactions, mountLocale };
}
