import { exports, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
	worker: {
		name: "syncstr-rendezvous",
		compatibilityDate: "2026-10-09",
		entrypoint,
		exports: { PeerRecord: exports.durableObject({ storage: "sqlite" }) },
		observability: { enabled: true, redactQueryString: true, traces: { enabled: true } },
	},
});
