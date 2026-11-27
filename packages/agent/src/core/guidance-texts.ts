import { functionGuidance } from "../functions/guidance";
import { providerIdentity } from "./provider-prompts";

export const guidanceTexts: Record<string, string> = {
  ...functionGuidance,
  "namespace.output": "Retrieve complete captured JavaScript output.",
  "provider.claude-subscription.identity": providerIdentity("claude-subscription"),
  "output.cacheExceeded": "Output exceeds the 32 MiB output storage limit.",
  "output.expired": "This saved JavaScript output is no longer available; older output is removed when newer output needs space. Rerun only read-only or confirmed safe operations, filtering results before printing.",
  "image.fileRead": "Use ox.vision.analyze for on-device OCR and classification, or ox.fs.attach with a Profile-relative file path when original pixels are needed.",
  "file.conversion": "This file type can't be read as text. Use ox.fs.attach if the selected provider supports its format, or convert it to text, an image, or PDF."
};

export function guidanceText(key: string) {
  const text = guidanceTexts[key];
  if (!Object.hasOwn(guidanceTexts, key)) throw new Error(`Unknown model guidance: ${key}`);
  return text;
}
