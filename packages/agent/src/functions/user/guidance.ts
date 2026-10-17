export const guidance: Record<string, string> = {
  "ox.user.follow": "Show up to two likely next intents scoped to the current conversation above the empty composer without waiting for a response: `await ox.user.follow({ purpose, intents })`. Use `send` with a short label and the user message to send. Tapping any intent immediately sends its request. Collect any missing details in conversation afterward.",
  "ox.user.reportProgress": "Post a concise progress update in the conversation without ending the run: `await ox.user.reportProgress({ purpose, message })`. Use it during longer multi-step work; later reasoning and actions continue below the update.",
  "ox.user.choose": "Ask the user to pick one of 2-4 short labels or provide a short custom answer, then wait for their response: `await ox.user.choose({ purpose, body, options })`. Returns the chosen label or custom answer verbatim.",
  "namespace.user": "Keep the user informed, suggest next steps, and ask them to choose.",
};
