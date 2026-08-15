# Music Player Operations Implementation Plan

**Goal:** Operate the NAS service securely, recoverably, and with auditable deployments.

**Architecture:** Docker Compose is the initial deployment; HTTPS terminates at a reverse proxy. Production data, credentials, fixtures, and validation databases are strictly separate.

**Dependencies:** server health/backup APIs; passkey AuthService; deployment environment decisions.

## Boundaries

| Component | API / data boundary | Evidence |
| --- | --- | --- |
| Reverse proxy | public HTTPS → private `/v1` | TLS and rate-limit integration tests |
| Backup runner | DB/events/sidecars/config → encrypted manifest | isolated restore drill |
| Audit and retention | auth/trash/compaction records | revocation and retention tests |

## Implementation order

1. Define Compose production topology, internal network, localhost-only admin endpoints, health checks, resource limits, and configuration validation tests.
2. Configure HTTPS reverse proxy, HSTS, certificate renewal, request-size/rate limits, and no direct media-service exposure.
3. Make passkey registration the default first-login flow; add device list, token rotation, revocation, and audit-log tests.
4. Implement encrypted/offsite backup manifests for SQLite, events, sidecars, configuration, and media inventory; test restore into an isolated environment.
5. Implement trash retention, restore authorization, permanent purge approval, and event compaction only after the 90-day tombstone/cursor rule.
6. Add metrics, structured logs without credentials, alerts, incident recovery runbooks, and dependency/OSS license audit in CI.

## Acceptance and risks

- Restore drills prove data consistency and a revoked device cannot refresh credentials.
- HTTPS, rate limits, backup, trash, and OSS audit each have an automated check plus an operator runbook.
- Navidrome validation compose is not production configuration; authenticated adapter results remain BLOCKED.
- Retention periods, backup destination/encryption keys, proxy choice, and OSS disclosure policy require owner decisions.

## Test cycles

- Add a failing configuration or restore test before each Compose, proxy, backup, or retention change.
- Exercise recovery and revocation in an isolated deployment; production credentials and validation fixtures are never reused.
