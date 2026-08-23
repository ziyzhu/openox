import type { ActionInstaller } from "../action.ts";
import { cleanText } from "../../../action-lib.ts";

export const normalizeGmailThreadId = (value: string) => {
  const normalized = cleanText(value);
  const numeric = normalized.match(/^#?thread-[A-Za-z]:(\d+)$/);
  if (numeric) return BigInt(numeric[1]).toString(16);
  if (/^[A-Za-z0-9_-]+$/.test(normalized)) return normalized;
  throw new Error("Gmail thread id is invalid");
};

export const normalizeGmailRecipients = (values: unknown) => {
  if (!Array.isArray(values)) throw new Error("Gmail recipients must be an array");
  const recipients = new Map<string, string>();
  for (const value of values) {
    const recipient = cleanText(value);
    if (!/^[^\s@]+@[^\s@]+$/.test(recipient)) throw new Error(`Gmail recipient is invalid: ${recipient || "empty value"}`);
    recipients.set(recipient.toLowerCase(), recipient);
  }
  return [...recipients.values()];
};

const install: ActionInstaller = ({ action, retryFetch, log }) => {
  const ORIGIN = "https://mail.google.com";
  const MAIL_ROOT = `${ORIGIN}/mail/u/0/`;
  const BOOTSTRAP_URL = `${ORIGIN}/mail/_/bscframe`;
  const ACCOUNTS_URL = "https://accounts.google.com/ListAccounts?gpsia=1&source=Ox&json=standard";
  const MAILBOXES = new Set(["inbox", "starred", "sent", "drafts", "spam", "trash", "all"]);

  type NavigationTarget =
    | { kind: "mailbox"; mailbox: string; cursor?: string }
    | { kind: "search"; query: string; cursor?: string };

  const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

  const waitFor = async <T>(read: () => T | null | undefined | false, context: string, timeoutMs = 20000): Promise<T> => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const value = read();
      if (value) return value as T;
      await sleep(100);
    }
    throw new Error(`${context}: timed out`);
  };

  const decodeListAccountsPayload = (text: string) => {
    const trimmed = text.trim();
    if (trimmed.startsWith("[")) return trimmed;
    const match = trimmed.match(/postMessage\('((?:\\.|[^'])*)'/);
    if (!match) throw new Error("Google account list response was not recognized");
    return match[1]
      .replace(/\\x([0-9a-f]{2})/gi, (_, value) => String.fromCharCode(Number.parseInt(value, 16)))
      .replace(/\\u([0-9a-f]{4})/gi, (_, value) => String.fromCharCode(Number.parseInt(value, 16)))
      .replace(/\\\//g, "/")
      .replace(/\\'/g, "'")
      .replace(/\\\\/g, "\\");
  };

  const availableAccounts = async () => {
    const response = await retryFetch(ACCOUNTS_URL, { credentials: "include" });
    if (!response.ok) throw new Error(`Google account list: HTTP ${response.status}`);
    const payload = JSON.parse(decodeListAccountsPayload(await response.text()));
    if (!Array.isArray(payload) || !Array.isArray(payload[1])) {
      throw new Error("Google account list response was invalid");
    }
    const accounts = payload[1]
      .filter((entry: unknown) => Array.isArray(entry)
        && typeof entry[3] === "string"
        && entry[3].includes("@")
        && entry[9] !== 0
        && entry[9] !== false
        && entry[14] !== 1
        && entry[14] !== true)
      .map((entry: unknown[], index: number) => ({
        accountId: String(entry[3]),
        email: String(entry[3]),
        primary: index === 0,
      }));
    log(`listAccounts accounts=${accounts.length}`);
    return accounts;
  };

  const resolveAccount = async (accountId?: string) => {
    const accounts = await availableAccounts();
    if (accounts.length === 0) throw new Error("No signed-in Gmail accounts are available");
    if (!accountId) return accounts[0];
    const account = accounts.find(({ accountId: candidate }) => candidate.toLowerCase() === accountId.toLowerCase());
    if (account) return account;
    throw new Error(`Gmail account is not available: ${accountId}`);
  };

  const accountURL = (accountId: string, hash?: string) => {
    const url = new URL(`${ORIGIN}/mail/u/`);
    url.searchParams.set("authuser", accountId);
    if (hash) url.hash = hash.startsWith("#") ? hash.slice(1) : hash;
    return url;
  };

  const mailboxDocument = () => {
    if (location.hostname !== "mail.google.com") return null;
    if (!document.querySelector('[gh="cm"], [role="main"], [data-thread-id]')) return null;
    return document;
  };

  const ensureMailbox = async () => waitFor(mailboxDocument, "Gmail mailbox", 30000);

  const probeMailbox = async () => {
    const response = await retryFetch(MAIL_ROOT, {
      credentials: "include",
      redirect: "manual",
    });
    return response.ok && response.type !== "opaqueredirect";
  };

  const normalizedHash = (value: string) => {
    try {
      return decodeURIComponent(value);
    } catch {
      return value;
    }
  };

  const targetHash = (target: NavigationTarget) => {
    if (target.cursor) {
      const cursor = normalizedHash(target.cursor);
      if (!cursor.startsWith("#")) throw new Error("Gmail cursor is invalid");
      if (target.kind === "mailbox" && !new RegExp(`^#${target.mailbox}/p\\d+$`).test(cursor)) {
        throw new Error("Gmail cursor is not a mailbox page returned by the previous result");
      }
      if (target.kind === "search" && !/^#search\/.+\/p\d+$/.test(cursor)) {
        throw new Error("Gmail cursor is not a search page returned by the previous result");
      }
      return target.cursor;
    }
    return target.kind === "mailbox"
      ? `#${target.mailbox}`
      : `#search/${encodeURIComponent(target.query)}`;
  };

  const threadId = (element: HTMLElement) => {
    const legacy = element.getAttribute("data-legacy-thread-id")
      || element.closest<HTMLElement>("[data-legacy-thread-id]")?.getAttribute("data-legacy-thread-id");
    const value = legacy || element.getAttribute("data-thread-id") || "";
    try {
      return normalizeGmailThreadId(value);
    } catch {
      return "";
    }
  };

  const threadRows = (doc: Document) => {
    const rows = new Map<string, HTMLElement>();
    for (const element of doc.querySelectorAll<HTMLElement>("[data-thread-id]")) {
      const id = threadId(element);
      if (!id || rows.has(id)) continue;
      const row = element.closest<HTMLElement>('tr, [role="row"]') || element;
      const rects = row.getClientRects?.();
      if (rects && rects.length === 0) continue;
      rows.set(id, row);
    }
    return [...rows.entries()].map(([id, row]) => ({ id, row }));
  };

  const rowSignature = (doc: Document) => threadRows(doc).map(({ id }) => id).join(",");

  const navigate = async (target: NavigationTarget, hash: string, context: string) => {
    let doc = await ensureMailbox();
    const desired = normalizedHash(hash);
    const previousSignature = rowSignature(doc);
    const routeChanged = normalizedHash(location.hash) !== desired;
    if (normalizedHash(location.hash) !== desired) location.hash = hash.slice(1);
    await waitFor(() => normalizedHash(location.hash) === desired, `${context}: route`);
    if (target.kind === "search" && routeChanged && !target.cursor) {
      const input = await waitFor(() => {
        const candidate = mailboxDocument()?.querySelector<HTMLInputElement>('input[name="q"]');
        return cleanText(candidate?.value) === cleanText(target.query) ? candidate : null;
      }, `${context}: query`);
      if (typeof KeyboardEvent === "function") {
        for (const type of ["keydown", "keypress", "keyup"]) {
          input.dispatchEvent(new KeyboardEvent(type, {
            key: "Enter",
            code: "Enter",
            keyCode: 13,
            which: 13,
            bubbles: true,
            cancelable: true,
          }));
        }
      }
      await sleep(300);
    }
    doc = await waitFor(() => {
      const candidate = mailboxDocument();
      if (!candidate) return null;
      if (target.kind === "search") {
        const query = cleanText(candidate.querySelector<HTMLInputElement>('input[name="q"]')?.value);
        if (query !== cleanText(target.query)) return null;
      }
      if (routeChanged && previousSignature && rowSignature(candidate) === previousSignature) return null;
      return candidate;
    }, `${context}: content`);
    await sleep(300);
    return doc;
  };

  const contactText = (element: Element) => {
    const name = cleanText(element.getAttribute("name") || element.textContent);
    const email = cleanText(element.getAttribute("email") || element.getAttribute("data-hovercard-id"));
    if (name && email && name.toLowerCase() !== email.toLowerCase()) return `${name} <${email}>`;
    return email || name;
  };

  const participants = (row: HTMLElement) => {
    const values = new Set<string>();
    for (const element of row.querySelectorAll("[email], [data-hovercard-id]")) {
      const value = contactText(element);
      if (value) values.add(value);
    }
    if (values.size === 0) {
      const sender = cleanText(row.querySelector(".yW, .yP, .zF")?.textContent);
      if (sender) values.add(sender);
    }
    return [...values];
  };

  const titledText = (element: Element | null) =>
    cleanText(element?.getAttribute("title") || element?.getAttribute("data-tooltip") || element?.textContent);

  const threadSummary = ({ id, row }: { id: string; row: HTMLElement }, accountId: string) => ({
    accountId,
    id,
    subject: cleanText(row.querySelector(".bog, .y6 span[id], [data-thread-perm-id]")?.textContent),
    participants: participants(row),
    snippet: cleanText(row.querySelector(".y2, .Zt")?.textContent).replace(/^[-–—]\s*/, ""),
    latestAt: titledText(row.querySelector(".xW span[title], .xW span, td[title]")),
    unread: row.classList.contains("zE") || row.getAttribute("aria-label")?.toLowerCase().includes("unread") === true,
    starred: Boolean(row.querySelector('.T-KT-Jp, [aria-label*="Starred"], [title*="Starred"]')),
    hasAttachments: Boolean(row.querySelector('.brd, [aria-label*="Attachment"], [title*="Attachment"]')),
    url: accountURL(accountId, `#all/${encodeURIComponent(id)}`).toString(),
  });

  const olderButton = (doc: Document) => {
    const candidates = doc.querySelectorAll<HTMLElement>(
      '[aria-label*="Older"], [data-tooltip*="Older"], [title*="Older"]',
    );
    for (const element of candidates) {
      const disabled = element.getAttribute("aria-disabled") === "true"
        || element.hasAttribute("disabled")
        || element.classList.contains("T-I-JO");
      if (!disabled) return element;
    }
    return null;
  };

  const nextCursor = (doc: Document, hash: string) => {
    if (!olderButton(doc)) return null;
    const decoded = normalizedHash(hash);
    const match = decoded.match(/\/p(\d+)$/);
    const page = match ? Number(match[1]) : 1;
    const base = match ? decoded.slice(0, match.index) : decoded;
    return `${base}/p${page + 1}`;
  };

  const listPage = async (target: NavigationTarget, accountId: string) => {
    const hash = targetHash(target);
    const context = target.kind === "mailbox" ? `list ${target.mailbox}` : "search Gmail";
    const doc = await navigate(target, hash, context);
    const items = threadRows(doc).map((row) => threadSummary(row, accountId));
    const cursor = nextCursor(doc, hash);
    log(`${target.kind} account=${accountId} route=${normalizedHash(hash).replace(/\/p\d+$/, "/p…")} items=${items.length} next=${cursor !== null}`);
    return { accountId, items, nextCursor: cursor };
  };

  const bodyText = (element: HTMLElement | null) =>
    String(element?.innerText || element?.textContent || "")
      .replace(/\r\n?/g, "\n")
      .replace(/[ \t]+\n/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();

  const attachmentRows = (scope: ParentNode) => {
    const attachments = new Map<string, { name: string; size: string }>();
    const names = scope.querySelectorAll<HTMLElement>(".aV3, [download]");
    for (const element of names) {
      const name = cleanText(element.getAttribute("download") || element.textContent);
      if (!name) continue;
      const container = element.closest<HTMLElement>(".aQy, .aQH, .aZo") || element.parentElement;
      const size = cleanText(container?.querySelector(".SaH2Ve, .aV4")?.textContent);
      attachments.set(`${name}\n${size}`, { name, size });
    }
    return [...attachments.values()];
  };

  const printableMessages = (doc: Document) => {
    const messageRoots = [
      ...doc.querySelectorAll<HTMLElement>("[data-message-id], .message"),
    ];
    const seen = new Set<string>();
    const messages = [];
    for (const root of messageRoots) {
      const printable = root.matches("table.message");
      const body = root.querySelector<HTMLElement>(".a3s, [dir=\"ltr\"], [dir=\"auto\"]")
        || (printable ? root.querySelector<HTMLElement>(":scope > tbody > tr:nth-child(3) > td") : null);
      if (!body) continue;
      const id: string = root.getAttribute("data-message-id")
        || `message-${messages.length + 1}`;
      if (seen.has(id)) continue;
      seen.add(id);
      const fromNode = root.querySelector(".gD[email], [email], [data-hovercard-id]");
      messages.push({
        id,
        from: fromNode
          ? contactText(fromNode)
          : titledText(root.querySelector(printable ? ":scope > tbody > tr:first-child > td:first-child" : ".gD, .from")),
        recipients: titledText(root.querySelector(printable ? ".recipient" : ".hb, .g2, .to")),
        sentAt: titledText(root.querySelector(printable ? ":scope > tbody > tr:first-child > td:last-child" : ".g3[title], .g3, .date")),
        body: bodyText(body),
        attachments: attachmentRows(root),
      });
    }
    if (messages.length > 0) return messages;
    const bodies = [...doc.querySelectorAll<HTMLElement>(".a3s")];
    return bodies.map((body, index) => ({
      id: `message-${index + 1}`,
      from: "",
      recipients: "",
      sentAt: "",
      body: bodyText(body),
      attachments: attachmentRows(body.parentElement || body),
    }));
  };

  const withHTMLDocument = async <T>(html: string, read: (doc: Document) => T) => {
    const blobUrl = URL.createObjectURL(new Blob([html], { type: "text/html" }));
    const frame = document.createElement("iframe");
    frame.hidden = true;
    frame.setAttribute("aria-hidden", "true");
    frame.setAttribute("sandbox", "allow-same-origin");
    const loaded = new Promise<void>((resolve, reject) => {
      frame.addEventListener("load", () => resolve(), { once: true });
      frame.addEventListener("error", () => reject(new Error("Gmail conversation document failed to load")), { once: true });
    });
    frame.src = blobUrl;
    (document.body || document.documentElement).append(frame);
    try {
      await loaded;
      const doc = frame.contentDocument;
      if (!doc) throw new Error("Gmail conversation document was unavailable");
      return read(doc);
    } finally {
      frame.remove();
      URL.revokeObjectURL(blobUrl);
    }
  };

  const threadSubject = (doc: Document) => {
    const heading = cleanText(doc.querySelector("h2.hP, h2[data-thread-perm-id]")?.textContent);
    if (heading) return heading;
    return cleanText(doc.title)
      .replace(/^Gmail\s*[-–—:]\s*/i, "")
      .replace(/\s+-\s+[^-]+@[^-]+\s+-\s+Gmail$/, "");
  };

  const printThread = async (id: string, accountId: string) => {
    const url = accountURL(accountId);
    url.searchParams.set("ui", "2");
    url.searchParams.set("view", "pt");
    url.searchParams.set("search", "all");
    url.searchParams.set("th", id);
    const response = await retryFetch(url.toString(), { credentials: "include" });
    const html = await response.text();
    if (response.status === 400) throw new Error("Gmail conversation was not available for the selected thread id");
    if (!response.ok) throw new Error(`Gmail printable conversation: HTTP ${response.status}`);
    if (/accounts\.google\.com\/ServiceLogin/.test(html)) {
      throw new Error("Gmail session expired. Sign in again.");
    }
    return withHTMLDocument(html, (doc) => {
      const messages = printableMessages(doc);
      if (messages.length === 0) throw new Error("Gmail printable conversation contained no readable messages");
      log(`getThread account=${accountId} mode=printable idLength=${id.length} messages=${messages.length}`);
      return {
        accountId,
        id,
        subject: threadSubject(doc),
        messages,
        url: accountURL(accountId, `#all/${encodeURIComponent(id)}`).toString(),
      };
    });
  };

  type DraftFields = {
    to?: string[];
    subject?: string;
    body?: string;
  };

  const composeDialogs = () => [...document.querySelectorAll<HTMLElement>('[role="dialog"]')]
    .filter((element) => element.getClientRects().length > 0 && element.querySelector('input[name="draft"]'));

  const composeBody = (dialog: HTMLElement) => dialog.querySelector<HTMLElement>(
    '[contenteditable="true"][aria-label="Message Body"], [contenteditable="true"][role="textbox"]',
  );

  const activate = (element: HTMLElement) => {
    for (const type of ["mousedown", "mouseup", "click"]) {
      element.dispatchEvent(new MouseEvent(type, {
        bubbles: true,
        cancelable: true,
        button: 0,
      }));
    }
  };

  const ensureComposeExpanded = async (dialog: HTMLElement) => {
    const body = composeBody(dialog);
    if (!body) throw new Error("Gmail message editor was unavailable");
    if (body.getClientRects().length > 0) return dialog;
    const maximize = [...dialog.querySelectorAll<HTMLElement>('[role="button"], button')]
      .find((element) => element.getClientRects().length > 0
        && (cleanText(element.getAttribute("aria-label")) === "Maximize"
          || cleanText(element.getAttribute("data-tooltip")) === "Maximize"));
    if (!maximize) throw new Error("Gmail draft was minimized and could not be expanded");
    maximize.click();
    await waitFor(() => body.getClientRects().length > 0, "Gmail draft expanded");
    return dialog;
  };

  const composeIdentity = (dialog: HTMLElement) => {
    const id = cleanText(dialog.querySelector<HTMLInputElement>('input[name="draft"]')?.value);
    const threadId = cleanText(dialog.querySelector<HTMLInputElement>('input[name="rt"]')?.value);
    return id && threadId ? { id, threadId } : null;
  };

  const recipientInput = (dialog: HTMLElement) => dialog.querySelector<HTMLInputElement>(
    'input[aria-label="To recipients"], input[role="combobox"][type="text"]',
  );

  const recipientContainer = (dialog: HTMLElement) => {
    const input = recipientInput(dialog);
    return input?.closest<HTMLElement>('[aria-label="To"], .anm') || null;
  };

  const selectedRecipients = (dialog: HTMLElement) => {
    const container = recipientContainer(dialog);
    if (!container) return [];
    const recipients = new Map<string, string>();
    for (const chip of container.querySelectorAll<HTMLElement>('[role="option"][data-hovercard-id]')) {
      const email = cleanText(chip.getAttribute("data-hovercard-id"));
      if (/^[^\s@]+@[^\s@]+$/.test(email)) recipients.set(email.toLowerCase(), email);
    }
    return [...recipients.values()];
  };

  const setInputValue = (input: HTMLInputElement, value: string) => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
    if (!setter) throw new Error("Gmail input editor was unavailable");
    input.focus();
    setter.call(input, value);
    input.dispatchEvent(new InputEvent("input", {
      bubbles: true,
      composed: true,
      inputType: "insertText",
      data: value,
    }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  };

  const setRecipients = async (dialog: HTMLElement, values: string[]) => {
    await ensureComposeExpanded(dialog);
    const recipients = normalizeGmailRecipients(values);
    const input = recipientInput(dialog);
    const container = recipientContainer(dialog);
    if (!input || !container) throw new Error("Gmail recipient editor was unavailable");

    for (const chip of [...container.querySelectorAll<HTMLElement>('[role="option"][data-hovercard-id]')]) {
      const remove = chip.querySelector<HTMLElement>('[aria-label^="Press delete"]');
      if (!remove) throw new Error("Gmail recipient removal control was unavailable");
      remove.click();
    }
    await waitFor(() => selectedRecipients(dialog).length === 0, "Gmail recipients cleared");

    for (const recipient of recipients) {
      setInputValue(input, recipient);
      const option = await waitFor(() => [...document.querySelectorAll<HTMLElement>('[role="option"]')]
        .find((element) => element.getClientRects().length > 0
          && (cleanText(element.getAttribute("data-hovercard-id")).toLowerCase() === recipient.toLowerCase()
            || cleanText(element.textContent).toLowerCase().includes(recipient.toLowerCase()))), `Gmail recipient ${recipient}`);
      option.click();
      await waitFor(() => selectedRecipients(dialog).some((value) => value.toLowerCase() === recipient.toLowerCase()), `Gmail recipient ${recipient} selected`);
    }
    input.blur();
  };

  const setComposeBody = async (dialog: HTMLElement, value: string) => {
    await ensureComposeExpanded(dialog);
    const body = composeBody(dialog);
    if (!body) throw new Error("Gmail message editor was unavailable");
    body.focus();
    const selection = getSelection();
    const range = document.createRange();
    range.selectNodeContents(body);
    selection?.removeAllRanges();
    selection?.addRange(range);
    const changed = value
      ? document.execCommand("insertText", false, value)
      : document.execCommand("delete", false);
    if (!changed) throw new Error("Gmail message editor rejected the draft body");
    const expected = value.replace(/\r\n?/g, "\n").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
    await waitFor(() => bodyText(body) === expected, "Gmail draft body saved");
  };

  const touchComposeBody = async (dialog: HTMLElement) => {
    await ensureComposeExpanded(dialog);
    const body = composeBody(dialog);
    if (!body) throw new Error("Gmail message editor was unavailable");
    body.focus();
    const selection = getSelection();
    const range = document.createRange();
    range.selectNodeContents(body);
    range.collapse(false);
    selection?.removeAllRanges();
    selection?.addRange(range);
    if (!document.execCommand("insertText", false, " ")) throw new Error("Gmail message editor rejected the draft update");
    if (!document.execCommand("delete", false)) throw new Error("Gmail message editor could not finalize the draft update");
  };

  const draftBodyText = (element: HTMLElement | null) => {
    if (!element) return "";
    const read = (node: Node, root = false): string => {
      if (node.nodeType === Node.TEXT_NODE) return node.nodeValue || "";
      if (!(node instanceof HTMLElement)) return "";
      if (node.tagName === "BR") return "\n";
      const value = [...node.childNodes].map((child) => read(child)).join("");
      return !root && /^(DIV|P)$/.test(node.tagName) ? `\n${value}\n` : value;
    };
    return read(element, true)
      .replace(/\r\n?/g, "\n")
      .replace(/[ \t]+\n/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  };

  const applyDraftFields = async (dialog: HTMLElement, fields: DraftFields) => {
    if (fields.to !== undefined) await setRecipients(dialog, fields.to);
    if (fields.subject !== undefined) {
      await ensureComposeExpanded(dialog);
      const subject = dialog.querySelector<HTMLInputElement>('input[name="subjectbox"]');
      if (!subject) throw new Error("Gmail subject editor was unavailable");
      setInputValue(subject, fields.subject);
    }
    if (fields.body !== undefined) await setComposeBody(dialog, fields.body);
    else await touchComposeBody(dialog);
    if (fields.subject !== undefined) {
      await waitFor(() => dialog.querySelector<HTMLInputElement>('input[name="subject"]')?.value === fields.subject, "Gmail draft subject saved");
    }
    await sleep(700);
  };

  const draftSnapshot = (dialog: HTMLElement, accountId: string) => {
    const identity = composeIdentity(dialog);
    if (!identity) throw new Error("Gmail draft identifiers were unavailable");
    const { id, threadId } = identity;
    const subject = dialog.querySelector<HTMLInputElement>('input[name="subjectbox"]')?.value || "";
    const body = draftBodyText(composeBody(dialog));
    return {
      accountId,
      id,
      threadId,
      to: selectedRecipients(dialog),
      subject,
      body,
      url: accountURL(accountId, location.hash).toString(),
    };
  };

  const openNewDraft = async () => {
    const doc = await ensureMailbox();
    const existing = new Set(composeDialogs().flatMap((dialog) => composeIdentity(dialog)?.id || []));
    const compose = doc.querySelector<HTMLElement>('[gh="cm"]')
      || [...doc.querySelectorAll<HTMLElement>('[role="button"]')].find((element) => cleanText(element.textContent) === "Compose");
    if (!compose) throw new Error("Gmail Compose button was unavailable");
    compose.click();
    const dialog = await waitFor(() => composeDialogs().find((candidate) => {
      const identity = composeIdentity(candidate);
      return identity && !existing.has(identity.id);
    }), "Gmail new draft");
    return ensureComposeExpanded(dialog);
  };

  const draftRow = (doc: Document, threadId: string) => [...doc.querySelectorAll<HTMLElement>('tr, [role="row"]')]
    .find((row) => {
      const elements = row.matches("[data-thread-id]")
        ? [row, ...row.querySelectorAll<HTMLElement>("[data-thread-id]")]
        : [...row.querySelectorAll<HTMLElement>("[data-thread-id]")];
      return elements.some((element) => cleanText(element.getAttribute("data-thread-id")) === threadId);
    });

  const openDraft = async (id: string, threadId: string) => {
    const existing = composeDialogs().find((dialog) => {
      const identity = composeIdentity(dialog);
      return identity?.id === id && identity.threadId === threadId;
    });
    if (existing) return ensureComposeExpanded(existing);
    const doc = await navigate({ kind: "mailbox", mailbox: "drafts" }, "#drafts", "open Gmail draft");
    const row = await waitFor(() => draftRow(doc, threadId), "Gmail draft row");
    row.click();
    const dialog = await waitFor(() => composeDialogs().find((candidate) => {
      const identity = composeIdentity(candidate);
      return identity?.id === id && identity.threadId === threadId;
    }), "Gmail draft editor");
    return ensureComposeExpanded(dialog);
  };

  const requireDraftIdentity = (id: unknown, threadId: unknown) => {
    const draftId = cleanText(id);
    const draftThreadId = cleanText(threadId);
    if (!/^#msg-[A-Za-z]:[A-Za-z0-9_-]+$/.test(draftId)) throw new Error("Gmail draft id is invalid");
    if (!/^#thread-[A-Za-z]:[A-Za-z0-9_-]+$/.test(draftThreadId)) throw new Error("Gmail draft thread id is invalid");
    return { id: draftId, threadId: draftThreadId };
  };

  action("getSignInUrl", {
    async invoke() {
      const continueUrl = encodeURIComponent(`${MAIL_ROOT}#inbox`);
      return { url: `https://accounts.google.com/ServiceLogin?service=mail&continue=${continueUrl}` };
    },
  });

  action("getSignInState", {
    async invoke() {
      const signedIn = await probeMailbox();
      log(`getSignInState signedIn=${signedIn}`);
      return { signedIn };
    },
  });

  action("listAccounts", {
    async invoke() {
      return { accounts: await availableAccounts() };
    },
  });

  action("listThreads", {
    async invoke({ accountId, mailbox = "inbox", cursor }: { accountId?: string; mailbox?: string; cursor?: string } = {}) {
      if (!MAILBOXES.has(mailbox)) throw new Error(`Unsupported Gmail mailbox: ${mailbox}`);
      const account = await resolveAccount(accountId);
      return listPage({ kind: "mailbox", mailbox, cursor }, account.accountId);
    },
  });

  action("searchThreads", {
    async invoke({ accountId, query, cursor }: { accountId?: string; query?: string; cursor?: string } = {}) {
      const value = cleanText(query);
      if (!value) throw new Error("Gmail search query is required");
      const account = await resolveAccount(accountId);
      return listPage({ kind: "search", query: value, cursor }, account.accountId);
    },
  });

  action("getThread", {
    async invoke({ accountId, id }: { accountId?: string; id?: string } = {}) {
      const value = normalizeGmailThreadId(cleanText(id));
      if (!/^[A-Fa-f0-9]+$/.test(value)) {
        throw new Error("Gmail conversation URL ids must be resolved with searchThreads or listThreads before reading");
      }
      const account = await resolveAccount(accountId);
      return printThread(value, account.accountId);
    },
  });

  action("createDraft", {
    async invoke({ accountId, to, subject, body }: { accountId?: string; to?: string[]; subject?: string; body?: string } = {}) {
      const recipients = normalizeGmailRecipients(to);
      if (recipients.length === 0) throw new Error("At least one Gmail recipient is required");
      const account = await resolveAccount(accountId);
      const dialog = await openNewDraft();
      await applyDraftFields(dialog, {
        to: recipients,
        subject: String(subject ?? ""),
        body: String(body ?? ""),
      });
      const draft = draftSnapshot(dialog, account.accountId);
      log(`createDraft account=${account.accountId} idLength=${draft.id.length} recipients=${draft.to.length} subjectLength=${draft.subject.length} bodyLength=${draft.body.length}`);
      return { draft };
    },
  });

  action("updateDraft", {
    async invoke({ accountId, id, threadId, to, subject, body }: { accountId?: string; id?: string; threadId?: string; to?: string[]; subject?: string; body?: string } = {}) {
      const identity = requireDraftIdentity(id, threadId);
      if (to === undefined && subject === undefined && body === undefined) throw new Error("At least one Gmail draft field is required");
      const account = await resolveAccount(accountId);
      const dialog = await openDraft(identity.id, identity.threadId);
      await applyDraftFields(dialog, {
        ...(to === undefined ? {} : { to: normalizeGmailRecipients(to) }),
        ...(subject === undefined ? {} : { subject: String(subject) }),
        ...(body === undefined ? {} : { body: String(body) }),
      });
      const draft = draftSnapshot(dialog, account.accountId);
      log(`updateDraft account=${account.accountId} idLength=${draft.id.length} recipients=${draft.to.length} subjectLength=${draft.subject.length} bodyLength=${draft.body.length}`);
      return { draft };
    },
  });

  action("sendDraft", {
    async invoke({ accountId, id, threadId }: { accountId?: string; id?: string; threadId?: string } = {}) {
      const identity = requireDraftIdentity(id, threadId);
      const account = await resolveAccount(accountId);
      const dialog = await openDraft(identity.id, identity.threadId);
      const draft = draftSnapshot(dialog, account.accountId);
      if (draft.to.length === 0) throw new Error("Gmail draft has no recipients");
      if (!draft.subject) throw new Error("Gmail draft has no subject");
      if (!draft.body) throw new Error("Gmail draft has no body");
      await sleep(500);
      const sendControls = [...dialog.querySelectorAll<HTMLElement>('[role="button"][data-tooltip^="Send"], [role="button"][aria-label^="Send"]')];
      const send = sendControls.find((element) => element.getClientRects().length > 0)
        || sendControls[0]
        || [...dialog.querySelectorAll<HTMLElement>('[role="button"]')].find((element) => cleanText(element.textContent) === "Send");
      if (!send) throw new Error("Gmail Send button was unavailable");
      log(`sendDraft controlVisible=${send.getClientRects().length > 0}`);
      if (send.getClientRects().length > 0) send.click();
      else activate(send);
      await waitFor(() => !document.contains(dialog), "Gmail draft sent");
      log(`sendDraft account=${account.accountId} idLength=${draft.id.length} recipients=${draft.to.length} subjectLength=${draft.subject.length} bodyLength=${draft.body.length}`);
      return {
        accountId: account.accountId,
        id: draft.id,
        threadId: draft.threadId,
        sent: true,
        url: accountURL(account.accountId, "#sent").toString(),
      };
    },
  });

  action("discardDraft", {
    async invoke({ accountId, id, threadId }: { accountId?: string; id?: string; threadId?: string } = {}) {
      const identity = requireDraftIdentity(id, threadId);
      const account = await resolveAccount(accountId);
      const dialog = await openDraft(identity.id, identity.threadId);
      await sleep(500);
      const discardControls = [...dialog.querySelectorAll<HTMLElement>('[aria-label^="Discard draft"]')];
      const discard = discardControls.find((element) => element.getClientRects().length > 0)
        || discardControls[0]
        || [...dialog.querySelectorAll<HTMLElement>('[role="button"]')].find((element) => cleanText(element.textContent) === "Discard draft");
      if (!discard) throw new Error("Gmail Discard draft button was unavailable");
      log(`discardDraft controlVisible=${discard.getClientRects().length > 0}`);
      if (discard.getClientRects().length > 0) discard.click();
      else activate(discard);
      await waitFor(() => !document.contains(dialog), "Gmail draft discarded");
      log(`discardDraft account=${account.accountId} idLength=${identity.id.length}`);
      return {
        accountId: account.accountId,
        id: identity.id,
        threadId: identity.threadId,
        discarded: true,
      };
    },
  });
};

export default install;
