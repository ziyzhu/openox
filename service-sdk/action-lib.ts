export function cookie(name: string): string | null {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = document.cookie.match(new RegExp(`(?:^|;\\s*)${escaped}=([^;]*)`));
  if (!match) return null;
  try { return decodeURIComponent(match[1]!); }
  catch { return match[1]!; }
}

export function cleanText(value: unknown): string {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

export function pageCursor(value: string | undefined, firstPage: number): number {
  return Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);
}
