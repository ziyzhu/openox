import { resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");

const REQUIRED_LOCALES = ["zh-Hans"];
const CATALOG_PATHS = [
  "apps/ios/OpenOx/Resources/Localizations/Localizable.xcstrings",
  "apps/ios/OpenOx/Resources/Localizations/InfoPlist.xcstrings",
  "apps/ios/ShareExtension/Localizable.xcstrings",
];
const PLACEHOLDER = /%(?:\d+\$)?(?:lld|ld|d|@|f|s)/g;

interface StringUnit {
  state?: string;
  value?: string;
}

interface CatalogEntry {
  shouldTranslate?: boolean;
  localizations?: Record<string, unknown>;
}

interface StringCatalog {
  strings?: Record<string, CatalogEntry>;
}

function stringUnits(value: unknown): StringUnit[] {
  if (Array.isArray(value)) return value.flatMap(stringUnits);
  if (value === null || typeof value !== "object") return [];
  const object = value as Record<string, unknown>;
  const current = object.stringUnit;
  const nested = Object.entries(object)
    .filter(([key]) => key !== "stringUnit")
    .flatMap(([, child]) => stringUnits(child));
  return current !== null && typeof current === "object"
    ? [current as StringUnit, ...nested]
    : nested;
}

function placeholders(value: string): string[] {
  return (value.match(PLACEHOLDER) ?? [])
    .map((placeholder) => placeholder.replace(/^%\d+\$/, "%"))
    .sort();
}

export function localizationErrors(catalog: StringCatalog, requiredLocales = REQUIRED_LOCALES): string[] {
  if (catalog.strings === undefined) return ["catalog has no strings object"];
  const errors: string[] = [];
  for (const [key, entry] of Object.entries(catalog.strings)) {
    if (entry.shouldTranslate === false) continue;
    for (const locale of requiredLocales) {
      const localization = entry.localizations?.[locale];
      if (localization === undefined) {
        errors.push(`${locale} missing: ${key}`);
        continue;
      }
      const units = stringUnits(localization);
      if (units.length === 0) {
        errors.push(`${locale} has no string unit: ${key}`);
        continue;
      }
      const expectedPlaceholders = placeholders(key);
      for (const unit of units) {
        if (unit.state !== "translated") errors.push(`${locale} is ${unit.state ?? "unstated"}: ${key}`);
        if (unit.value === undefined || unit.value.length === 0) {
          errors.push(`${locale} is empty: ${key}`);
          continue;
        }
        const actualPlaceholders = placeholders(unit.value);
        if (actualPlaceholders.join("\0") !== expectedPlaceholders.join("\0")) {
          errors.push(`${locale} placeholders differ: ${key}`);
        }
      }
    }
  }
  return errors;
}

export async function validateLocalizations(paths = CATALOG_PATHS): Promise<number> {
  let entries = 0;
  const failures: string[] = [];
  for (const path of paths) {
    const catalog = await Bun.file(resolve(ROOT, path)).json() as StringCatalog;
    entries += Object.keys(catalog.strings ?? {}).length;
    failures.push(...localizationErrors(catalog).map((error) => `${path}: ${error}`));
  }
  if (failures.length > 0) throw new Error(`Localization validation failed:\n${failures.join("\n")}`);
  return entries;
}

if (import.meta.main) {
  try {
    const entries = await validateLocalizations();
    console.log(`PASS localizations ${CATALOG_PATHS.length} catalogs, ${entries} entries`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
