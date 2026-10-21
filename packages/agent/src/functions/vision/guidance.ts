export const guidance: Record<string, string> = {
  "ox.vision.analyze": "Analyze one image with on-device OCR and classification: `await ox.vision.analyze({ purpose, source })`. Source may be a conversation or shared Profile-relative image path, or a file in a folder granted to this Profile under `files/<folder-id>/`. Image pixels stay on device; print only the returned text, dimensions, or labels needed for the task. Use `ox.fs.attach` when the model needs original pixels.",
  "namespace.vision": "Analyze stored images on device without attaching their pixels.",
};
