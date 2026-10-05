import { TextDecoder, TextEncoder } from "text-encoding";
// Loaded before whatwg-url (which uses encoding during module initialization).
Object.assign(globalThis, { TextDecoder, TextEncoder });
