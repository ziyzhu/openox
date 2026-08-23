const escapeHtml = (s: string) =>
  s.replace(/[&<>]/g, (c) => (c === "&" ? "&amp;" : c === "<" ? "&lt;" : "&gt;"));

const TOKEN = /("(?:\\u[a-fA-F0-9]{4}|\\[^u]|[^\\"])*"(?:\s*:)?|\b(?:true|false|null)\b|-?\d+\.?\d*(?:[eE][+-]?\d+)?)/g;

export const highlightJson = (json: string): string =>
  escapeHtml(json).replace(TOKEN, (m) => {
    const cls = m[0] === '"'
      ? (m.endsWith(":") ? "j-key" : "j-str")
      : m === "true" || m === "false" ? "j-bool"
      : m === "null" ? "j-null"
      : "j-num";
    return `<span class="${cls}">${m}</span>`;
  });
