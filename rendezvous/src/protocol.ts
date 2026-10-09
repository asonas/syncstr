export type Envelope = { payload: string; signature: string };
type Lookup = { kind: "lookup"; id: string; time: number; target: string };
export type Announcement = {
  kind: "announce"; id: string; time: number; expires: number; peers: string[];
  address: { version: 1; id: string; addresses: string[]; relay: null };
};
export function reply(status: number, body?: unknown): Response {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status, headers: { "Cache-Control": "no-store", "Content-Type": "application/json" },
  });
}
const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const isID = (value: unknown): value is string => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
function isCandidate(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 128) return false;
  const match = /^(\d{1,3}(?:\.\d{1,3}){3}|\[[a-fA-F0-9:]+\]):([0-9]{1,5})$/.exec(value);
  if (!match || Number(match[2]) < 1 || Number(match[2]) > 65535) return false;
  if (match[1].startsWith("[")) {
    try { return new URL(`http://${value}`).hostname.startsWith("["); }
    catch { return false; }
  }
  return match[1].split(".").every(part => Number(part) <= 255);
}
export async function verifyEnvelope(request: Request, path: string): Promise<
  { envelope: Envelope; payload: Announcement | Lookup } | Response
> {
  if (!request.headers.get("Content-Type")?.startsWith("application/json")) return reply(415);
  const reader = request.body?.getReader();
  if (!reader) return reply(400);
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > 32768) { await reader.cancel(); return reply(413); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try {
    const envelope: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
    if (!isObject(envelope) || typeof envelope.payload !== "string" || typeof envelope.signature !== "string") return reply(400);
    const payload: unknown = JSON.parse(envelope.payload);
    if (!isObject(payload) || !isID(payload.id) || typeof payload.time !== "number" || !Number.isSafeInteger(payload.time)
      || Math.abs(Date.now() - payload.time) > 60000) return reply(400);
    const signature = Uint8Array.from(atob(envelope.signature), character => character.charCodeAt(0));
    if (signature.length !== 64) return reply(400);
    const key = Uint8Array.from(payload.id.match(/../g)!, value => Number.parseInt(value, 16));
    const publicKey = await crypto.subtle.importKey("raw", key, "Ed25519", false, ["verify"]);
    if (!await crypto.subtle.verify("Ed25519", publicKey, signature,
      new TextEncoder().encode("syncstr-rendezvous-v1\n" + envelope.payload))) return reply(401);
    let validated: Announcement | Lookup;
    if (path === "/v1/lookup" && payload.kind === "lookup" && isID(payload.target)) {
      validated = { kind: "lookup", id: payload.id, time: payload.time, target: payload.target };
    } else if (path === "/v1/announce" && payload.kind === "announce") {
      const address = payload.address;
      if (typeof payload.expires !== "number" || !Number.isSafeInteger(payload.expires)
        || payload.expires <= Date.now() || payload.expires > payload.time + 300000
        || !Array.isArray(payload.peers) || payload.peers.length > 256 || !payload.peers.every(isID)
        || !isObject(address) || address.version !== 1 || address.id !== payload.id || address.relay !== null
        || !Array.isArray(address.addresses) || address.addresses.length < 1 || address.addresses.length > 32
        || !address.addresses.every(isCandidate)) return reply(400);
      validated = { kind: "announce", id: payload.id, time: payload.time, expires: payload.expires,
        peers: payload.peers, address: { version: 1, id: payload.id, addresses: address.addresses, relay: null } };
    } else return reply(400);
    return { payload: validated, envelope: { payload: envelope.payload, signature: envelope.signature } };
  } catch (error) {
    if (error instanceof SyntaxError || error instanceof TypeError || error instanceof DOMException) return reply(400);
    throw error;
  }
}
