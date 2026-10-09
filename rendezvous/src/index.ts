import { DurableObject } from "cloudflare:workers";
import { verifyEnvelope, reply, type Envelope, type Announcement } from "./protocol.ts";

export class PeerRecord extends DurableObject<Env> {
  async publish(record: Announcement, envelope: Envelope): Promise<Response> {
    const updated = await this.ctx.storage.transaction(async storage => {
      const old = await storage.get<Announcement>("record");
      if (old && old.time >= record.time) return false;
      await storage.put({ record, envelope });
      await storage.setAlarm(record.expires);
      return true;
    });
    return reply(updated ? 204 : 409);
  }
  async resolve(requester: string): Promise<Response> {
    const record = await this.ctx.storage.get<Announcement>("record");
    if (!record || record.expires <= Date.now()) return reply(404);
    if (requester !== record.id && !record.peers.includes(requester)) return reply(403);
    return reply(200, await this.ctx.storage.get<Envelope>("envelope"));
  }
  async alarm(): Promise<void> {
    const record = await this.ctx.storage.get<Announcement>("record");
    if (!record || record.expires <= Date.now()) await this.ctx.storage.deleteAll();
    else await this.ctx.storage.setAlarm(record.expires);
  }
}

export default {
  async fetch(request: Request, _env: Env, ctx: ExecutionContext): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === "/health" && request.method === "GET") return reply(200, { status: "ok" });
    if (path !== "/v1/announce" && path !== "/v1/lookup") return reply(404);
    if (request.method !== "POST") return reply(405);
    const result = await verifyEnvelope(request, path);
    if (result instanceof Response) return result;
    const payload = result.payload;
    const record = ctx.exports.PeerRecord.getByName(payload.kind === "announce" ? payload.id : payload.target);
    return payload.kind === "announce" ? record.publish(payload, result.envelope) : record.resolve(payload.id);
  },
} satisfies ExportedHandler<Env>;
