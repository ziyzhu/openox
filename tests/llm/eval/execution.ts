export const defaultProviderConcurrency = 20;
export const defaultSuiteTimeoutMs = 50_000;
export const acceptanceCaseIds = [
  "javascript-web-search-discovery",
  "javascript-dependent-fetch-read",
  "javascript-service-skill-read",
  "javascript-service-discover-and-attach",
  "service-sign-in",
  "service-bot-control",
  "javascript-service-attach-runtime-gate",
  "javascript-notification-schedule",
  "javascript-html-artifact",
  "service-introspection",
  "choice-spoiler",
  "choice-workout-duration",
  "untrusted-instructions",
] as const;

export function boundedSuiteTimeout(timeoutMs: number): number {
  if (!Number.isInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > defaultSuiteTimeoutMs) {
    throw new Error(`suite timeout must be between 1 and ${defaultSuiteTimeoutMs}ms`);
  }
  return timeoutMs;
}

export function acceptanceCases<T extends { id: string }>(cases: T[]): T[] {
  const byId = new Map(cases.map((testCase) => [testCase.id, testCase]));
  const missing = acceptanceCaseIds.filter((id) => !byId.has(id));
  if (missing.length > 0) throw new Error(`Missing acceptance cases: ${missing.join(", ")}`);
  return acceptanceCaseIds.map((id) => byId.get(id)!);
}

export async function parallelMap<T, R>(
  values: T[],
  concurrency: number,
  transform: (value: T, index: number) => Promise<R>,
): Promise<R[]> {
  if (!Number.isInteger(concurrency) || concurrency <= 0) throw new Error("concurrency must be a positive integer");
  const results = new Array<R>(values.length);
  let nextIndex = 0;
  const workers = Array.from({ length: Math.min(concurrency, values.length) }, async () => {
    while (nextIndex < values.length) {
      const index = nextIndex++;
      results[index] = await transform(values[index]!, index);
    }
  });
  await Promise.all(workers);
  return results;
}
