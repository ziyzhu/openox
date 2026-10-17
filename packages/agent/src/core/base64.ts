const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
export function decodeBase64(value: string) {
  if (typeof value !== "string" || value.length % 4 !== 0 || value.length > Math.ceil(32 * 1024 * 1024 / 3) * 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw new Error("Invalid bounded file Base64");
  const size = value.length / 4 * 3 - (value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0);
  const bytes = new Uint8Array(size);
  for (let start = 0, offset = 0; start < value.length; start += 4) {
    const bits = (alphabet.indexOf(value[start]!) << 18) | (alphabet.indexOf(value[start + 1]!) << 12)
      | (Math.max(0, alphabet.indexOf(value[start + 2]!)) << 6) | Math.max(0, alphabet.indexOf(value[start + 3]!));
    for (const shift of [16, 8, 0]) if (offset < size) bytes[offset++] = (bits >> shift) & 255;
  }
  return bytes;
}
export function encodeBase64(bytes: Uint8Array) {
  const parts: string[] = [];
  let part = "";
  for (let offset = 0; offset < bytes.length; offset += 3) {
    const bits = (bytes[offset]! << 16) | ((bytes[offset + 1] ?? 0) << 8) | (bytes[offset + 2] ?? 0);
    part += alphabet[(bits >> 18) & 63]! + alphabet[(bits >> 12) & 63]!
      + (offset + 1 < bytes.length ? alphabet[(bits >> 6) & 63]! : "=") + (offset + 2 < bytes.length ? alphabet[bits & 63]! : "=");
    if (part.length >= 16_384) { parts.push(part); part = ""; }
  }
  parts.push(part);
  return parts.join("");
}
