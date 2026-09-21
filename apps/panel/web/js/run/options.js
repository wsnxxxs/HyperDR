/* What an export is made from, and how two of them are compared.
 *
 * The runner sends these options, the result card calls itself stale when they
 * change, the header says whether the edit on screen has been exported, and the
 * export history marks the version that matches. Those four used to build the
 * comparison key separately; one definition keeps them from disagreeing about
 * whether a photograph is exported.
 */

import { toOptions } from "../settings/schema.js";
import { restoredModelId } from "../settings/model-ids.js";

export const runOptionsFor = (state) => ({
  ...toOptions(state),
  useModel: Boolean(state.previewOptimized),
  // The model is not a renderer setting, so it travels beside `useModel`. The
  // server resolves it against the executable's own table and rejects an id this
  // build cannot run, rather than falling back to a different algorithm.
  modelId: state.modelId,
  // Neither is the photo's domain: it is what the decoder reported, and it lets
  // the command builder keep an HDR source's precision in the Adaptive HDR base.
  sourceDomain: state.sourceDomain,
});

/** The comparison key for the edit in `state`. */
export const exportKeyFor = (state) => JSON.stringify(runOptionsFor(state));

/** The comparison key an export was made with, from its recorded options. */
export const entryKeyFor = (entry, state) => exportKeyFor({
  ...state, ...entry.options,
  previewOptimized: Boolean(entry.options?.useModel),
  modelId: restoredModelId(entry.options),
});

/** The selected result, when it was made from exactly the edit on screen. */
export const currentResult = (state) =>
  state.result && state.result.optionsKey === exportKeyFor(state) ? state.result : null;
