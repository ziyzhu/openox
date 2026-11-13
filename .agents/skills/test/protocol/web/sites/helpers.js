const usable = element => {
  if (!element || element.disabled || element.type === "hidden") return false;
  if (element.closest("[hidden], [aria-hidden='true'], [inert]")) return false;
  const style = getComputedStyle(element);
  return style.display !== "none" && style.visibility !== "hidden";
};

const waitForStep = async (detectors, timeout = 10000) => {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    for (const [kind, detect] of Object.entries(detectors)) {
      const match = detect();
      if (match) return { kind, match };
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  return { kind: "unknown", match: null };
};

const typeInto = (field, value) => {
  field.focus();
  Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value").set.call(field, value);
  field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: value }));
  field.dispatchEvent(new Event("change", { bubbles: true }));
};

const fetchJSON = async (path, init = {}) => {
  const response = await fetch(path, { credentials: "include", cache: "no-store", ...init });
  if (!response.ok) throw new Error(`${path} returned ${response.status}`);
  return response.json();
};

const fetchDocument = async path => {
  const response = await fetch(path, { credentials: "include", cache: "no-store" });
  if (!response.ok) throw new Error(`${path} returned ${response.status}`);
  return new DOMParser().parseFromString(await response.text(), "text/html");
};
