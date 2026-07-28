import type { AudiobookSettings, TTSCatalog, TTSSelection } from "../../api/types";

/**
 * The worker count after a TTS selection change. A model's measured
 * recommendation is a starting point, while a model's hard maximum applies
 * to remembered and manually edited values too. Mirrors AudiobookSettingsFields
 * in ProcessingSettingsSections.swift.
 */
export function workersAfterSelectionChange(input: {
  previous: AudiobookSettings;
  selection: TTSSelection;
  catalog: TTSCatalog | undefined;
  workersEdited: boolean;
}): number {
  const { previous, selection, catalog, workersEdited } = input;
  const modelChanged =
    selection.backendID !== previous.backendID || selection.modelID !== previous.modelID;
  const model = catalog?.models.find(
    (model) =>
      model.backendID === selection.backendID && model.modelID === selection.modelID,
  );
  const requested =
    modelChanged && !workersEdited
      ? (model?.recommendedAudiobookWorkers ?? previous.workers)
      : previous.workers;
  return Math.min(model?.maximumAudiobookWorkers ?? 8, requested);
}
