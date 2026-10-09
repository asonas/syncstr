import { test } from "node:test";
import assert from "node:assert/strict";
import { Miniflare } from "miniflare";
import { readFileSync } from "node:fs";

async function identity() {
  const pair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const id = Buffer.from(await crypto.subtle.exportKey("raw", pair.publicKey)).toString("hex");
  return { id, privateKey: pair.privateKey };
}
async function envelope(owner, payload) {
  const text = JSON.stringify({ id: owner.id, time: Date.now(), ...payload });
  const signature = await crypto.subtle.sign("Ed25519", owner.privateKey,
    new TextEncoder().encode("syncstr-rendezvous-v1\n" + text));
  return { payload: text, signature: Buffer.from(signature).toString("base64") };
}
function runtime() {
  return new Miniflare({ workers: [{ config: {
    name: "syncstr-rendezvous", compatibilityDate: "2026-10-09",
    exports: { PeerRecord: { type: "durable-object", storage: "sqlite" } },
    manifest: { mainModule: "index.js", modules: { "index.js": { type: "esm",
      contents: readFileSync(".cloudflare/output/v0/workers/default/bundle/index.js", "utf8") } } },
  } }] });
}
const announce = (owner, peers, time = Date.now(), lifetime = 120000) => ({ kind: "announce", time,
  expires: time + lifetime, peers: peers.map(peer => peer.id),
  address: { version: 1, id: owner.id, addresses: ["192.0.2.10:58024"], relay: null } });
const post = (mf, path, value) => mf.dispatchFetch("https://example.test/v1/" + path,
  { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(value) });

test("signed candidates can be resolved only by the owner or allowed peer", async () => {
  const mf = runtime();
  try {
    const owner = await identity(), peer = await identity(), stranger = await identity();
    const signed = await envelope(owner, announce(owner, [peer]));
    assert.equal((await post(mf, "announce", signed)).status, 204);
    for (const requester of [owner, peer]) {
      const response = await post(mf, "lookup", await envelope(requester, { kind: "lookup", target: owner.id }));
      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), signed);
      assert.equal(response.headers.get("Cache-Control"), "no-store");
    }
    assert.equal((await post(mf, "lookup", await envelope(stranger, { kind: "lookup", target: owner.id }))).status, 403);
    assert.equal((await post(mf, "lookup", await envelope(peer, { kind: "lookup", target: stranger.id }))).status, 404);
    assert.equal((await post(mf, "announce", signed)).status, 409);
    const newer = await envelope(owner, announce(owner, [], Date.now() + 10));
    assert.equal((await post(mf, "announce", newer)).status, 204);
    assert.equal((await post(mf, "lookup", await envelope(peer, { kind: "lookup", target: owner.id }))).status, 403);
  } finally { await mf.dispose(); }
});

test("tampering, stale requests, invalid candidates and excessive bodies are rejected", async () => {
  const mf = runtime();
  try {
    const owner = await identity();
    const signed = await envelope(owner, announce(owner, []));
    signed.payload = signed.payload.replace("58024", "58025");
    assert.equal((await post(mf, "announce", signed)).status, 401);
    assert.equal((await post(mf, "announce", await envelope(owner, announce(owner, [], Date.now() - 120000)))).status, 400);
    const invalid = announce(owner, []);
    invalid.address.addresses = ["https://example.test"];
    assert.equal((await post(mf, "announce", await envelope(owner, invalid))).status, 400);
    assert.equal((await post(mf, "announce", { payload: "x".repeat(32769), signature: "" })).status, 413);
  } finally { await mf.dispose(); }
});

test("expired records cannot be resolved", async () => {
  const mf = runtime();
  try {
    const owner = await identity();
    await mf.ready;
    const signed = await envelope(owner, announce(owner, [], Date.now(), 1000));
    assert.equal((await post(mf, "announce", signed)).status, 204);
    await new Promise(resolve => setTimeout(resolve, 1100));
    assert.equal((await post(mf, "lookup", await envelope(owner, { kind: "lookup", target: owner.id }))).status, 404);
  } finally { await mf.dispose(); }
});
