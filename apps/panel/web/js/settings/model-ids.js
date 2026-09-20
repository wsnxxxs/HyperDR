/* Model choices and recovery of saved configurations. */
export const MODEL_KEY = "modelId";
export const DEFAULT_MODEL_ID = "research-cnn-v1";
const MODEL_IDS = [DEFAULT_MODEL_ID, "research-exif-v1"];

export function availableModelIds(state) {
  const models = state?.capabilities?.model?.models;
  return Array.isArray(models)
    ? models.filter((entry) => entry?.available !== false && MODEL_IDS.includes(entry?.id))
      .map((entry) => entry.id)
    : [];
}

// Old or missing model selections use CNN; removed models cannot be restored.
export function restoredModelId(saved, available) {
  const ids = available?.length ? available.filter((id) => MODEL_IDS.includes(id)) : MODEL_IDS;
  const wanted = saved && typeof saved === "object" ? saved[MODEL_KEY] : undefined;
  return ids.includes(wanted) ? wanted : ids.includes(DEFAULT_MODEL_ID) ? DEFAULT_MODEL_ID : ids[0] || DEFAULT_MODEL_ID;
}
