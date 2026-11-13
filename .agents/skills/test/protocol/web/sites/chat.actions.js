const SERVICE = "web:ox-chat.localhost";
const submissions = new Map();

const consume = async (submission, reader) => {
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const frames = buffer.split("\n\n");
      buffer = frames.pop();
      for (const frame of frames) {
        const event = JSON.parse(frame.replace(/^data: /, ""));
        if (event.conversation) submission.accepted(event.conversation);
        else if (event.done) submission.events.push({ type: "completed", result: { url: null, files: [] } });
        else {
          submission.text += event.text;
          submission.events.push({ type: "text", text: submission.text });
        }
      }
    }
  } catch (error) {
    if (!submission.cancelled) submission.events.push({ type: "failed", message: String(error?.message ?? error), kind: "network" });
  }
  submission.finished = true;
};

const submit = async input => {
  if (input.conversationRef) throw new Error("Chat fixture does not support continuation");
  if (input.attachments.length) throw new Error("Chat fixture does not accept attachments");
  const controller = new AbortController();
  const submissionId = crypto.randomUUID();
  let accepted;
  const submission = { events: [], text: "", finished: false, cancelled: false, controller, conversation: new Promise(resolve => { accepted = resolve; }) };
  submission.accepted = accepted;
  submissions.set(submissionId, submission);
  const response = await fetch("/api/generate", { method: "POST", credentials: "include", signal: controller.signal,
    headers: { "content-type": "application/json" }, body: JSON.stringify({ model: input.modelId, messages: input.messages }) });
  if (!response.ok) throw new Error(`Generation returned ${response.status}`);
  consume(submission, response.body.getReader());
  const conversationRef = await submission.conversation;
  submission.conversationRef = conversationRef;
  return { operation: "submit", submissionId, conversationRef, submission: "confirmed", continuation: false, url: null };
};

const read = async input => {
  const submission = submissions.get(input.submissionId);
  if (!submission) throw new Error("Unknown submission");
  const end = Date.now() + input.waitMilliseconds;
  while (submission.events.length <= input.after && !submission.finished && Date.now() < end) await new Promise(resolve => setTimeout(resolve, 50));
  return { operation: "read", conversationRef: submission.conversationRef, url: null, nextCursor: submission.events.length, events: submission.events.slice(input.after) };
};

const cancel = input => {
  const submission = submissions.get(input.submissionId);
  if (!submission) throw new Error("Unknown submission");
  if (submission.finished) return { operation: "cancel", status: "completed" };
  submission.cancelled = true;
  submission.controller.abort();
  return { operation: "cancel", status: "cancelled" };
};

window.ox.install(({ action }) => {
  action("listSessions", {
    async invoke() {
      const { account } = await fetchJSON("/api/session");
      return account ? [{ id: account.id, label: account.label, url: `${location.origin}/` }] : [];
    },
  });

  action("login", {
    async invoke(input = {}, context) {
      const step = await waitForStep({
        signedIn: () => document.querySelector("#me"),
        password: () => usable(document.querySelector("#password")) ? document.querySelector("#password") : null,
        identifier: () => usable(document.querySelector("#username")) ? document.querySelector("#username") : null,
        entry: () => document.querySelector("#sign-in"),
      });
      if (step.kind === "unknown") throw new Error("Chat sign-in controls did not appear");
      if (step.kind === "signedIn") return null;
      if (step.kind === "entry") document.querySelector("#sign-in").click();
      if (!input.account || input.account.serviceID !== SERVICE) return null;
      const credentials = await context.secret(input.account);
      const username = await waitForStep({ field: () => usable(document.querySelector("#username")) && document.querySelector("#username") });
      if (username.kind === "unknown") throw new Error("Chat username field did not appear");
      typeInto(username.match, credentials.username);
      document.querySelector("#continue")?.click();
      const password = await waitForStep({ field: () => usable(document.querySelector("#password")) && document.querySelector("#password") });
      if (password.kind === "unknown") throw new Error("Chat password field did not appear on the same page");
      typeInto(password.match, credentials.password);
      document.querySelector("#submit").click();
      const outcome = await waitForStep({ signedIn: () => document.querySelector("#me"), error: () => usable(document.querySelector("[role=alert]")) && document.querySelector("[role=alert]") });
      if (outcome.kind === "error") throw new Error(`Chat sign-in reported: ${outcome.match.textContent.trim()}`);
      return null;
    },
  });

  action("listModels", {
    async invoke() {
      const { models } = await fetchJSON("/api/models");
      return { models: models.map(model => ({ id: model.id, name: model.name, input: ["text"], contextTokens: null, outputTokens: null,
        streaming: true, cancellation: true, options: [] })) };
    },
  });

  action("conversation", {
    async invoke(input) {
      if (input.operation === "submit") return submit(input);
      if (input.operation === "read") return read(input);
      return cancel(input);
    },
  });
});
