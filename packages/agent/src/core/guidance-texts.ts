import { functionGuidance } from "../functions/guidance";
import { providerIdentity } from "./provider-prompts";

export const guidanceTexts: Record<string, string> = {
  ...functionGuidance,
  "namespace.output": "Retrieve complete captured JavaScript output.",
  "provider.claude-subscription.identity": providerIdentity("claude-subscription"),
  "output.cacheExceeded": "JavaScript output cache exceeds 32 MiB. Filter results before printing and rerun the source.",
  "image.fileRead": "Use ox.vision.analyze for on-device OCR and classification, or ox.fs.attach with a Profile-relative file path when original pixels are needed.",
  "file.conversion": "This file type can't be read as text. Use ox.fs.attach if the selected provider supports its format, or convert it to text, an image, or PDF."
};

export function guidanceText(key: string) {
  const text = guidanceTexts[key];
  if (!Object.hasOwn(guidanceTexts, key)) throw new Error(`Unknown model guidance: ${key}`);
  return text;
}
