# API contract gate

Status: accepted design (ASO-80). The owner accepted the recommended option of every decision on 2026-11-07. This document does not change code, CI, or the wire protocol. Each slice below is delivered under its own issue.

## Problem

Syncstr has HTTP APIs that are implemented and consumed by programs that ship separately, but no machine-readable contract for them. A change that removes a field or tightens a request can pass every check today, because each implementation's tests only exercise that implementation.

The Jev review in CI is advisory. It reports quality and intent findings on the run summary, and it never stops a merge.

This design adds a PR gate. Code decides whether an API change is compatible, using an OpenAPI document as the contract. Jev findings are inputs to a deterministic decision rule, never the decision itself.

The design follows the structure of newmo's [riskjudge](https://tech.newmo.me/entry/2026/10/27/100000):

- Schema diffs are judged by code. Breaking changes stop, additive changes pass.
- The model returns findings. A pure function decides, and its exit code is the result.
- A change the gate cannot see or judge goes to a human.

The article covers GraphQL and Protocol Buffers. It does not mention OpenAPI or Jev, so their combination here is this project's own design.

## Terms

- **Surface**: one wire interface with a fixed set of producers and consumers.
- **Skew**: a producer and a consumer of one surface running different versions at the same time.
- **Contract**: the OpenAPI document for a surface. It is the reviewed definition that every implementation must follow.
- **Drift**: an implementation that no longer matches its contract.
- **Breaking change**: a contract change after which a consumer that followed the old contract can fail. oasdiff reports these at level `ERR`.
- **Unavailable**: a gate input that is missing, truncated, or failed. Unavailable always routes the PR to a human.

## Current state

### Surfaces

A contract gate pays only where skew exists. If producer and consumer always build from one commit, the compiler and the existing tests already catch a mismatch.

| Surface | Producer | Consumers | Skew |
| --- | --- | --- | --- |
| Rendezvous `/v1/announce`, `/v1/lookup` | Cloudflare Worker, `rendezvous/src/index.ts:31-32`, `rendezvous/src/protocol.ts:56-58` | headless, `headless/src/rendezvous.rs:82,113`; macOS app, `apps/macos/PeerTransfer.swift:120-158` | High. The Worker deploys separately from app builds and from headless nodes. Three languages implement one shape. |
| Shared-audio HTTPS `/v5/*` | `headless/src/shared_audio_api.rs:23-63`, served at `headless/src/main.rs:364` | headless CLI, `headless/src/client.rs:10-110` | Medium. A long-running node and a newer CLI on another machine can differ. Both live in one crate. |
| Legacy HTTPS `/v4/*` | `headless/src/api.rs:37-82`, served at `headless/src/main.rs:492` | headless CLI, `headless/src/client.rs:203-312` | Low value. The [shared-audio design](shared-audio-server-design.md) replaces it, and v1 to v3 already return `426`. |
| Cluster QUIC, ALPN `syncstr/cluster/5` and others | `headless/src/shared_audio_net.rs:1`, `headless/src/peer.rs:1` | macOS and iOS apps, `apps/macos/ClusterTransport.swift:477-513`; Windows and Android link the `syncstr-headless` crate | High. Swift reimplements the serde JSON messages. OpenAPI does not describe this surface. |

The largest skew surface, cluster QUIC, is outside what OpenAPI can describe without pretending QUIC streams are HTTP operations. This design leaves it out. See [Out of scope](#out-of-scope).

### Existing checks

| Check | Where | Notes |
| --- | --- | --- |
| Payload round trips | `headless/tests/contracts.rs`, `headless/fixtures/*.json` | Rust only. Asserts serde field names on real payloads. |
| Headless tests | `.github/workflows/verification.yml`, job `headless` | Runs on `pull_request` without secrets. |
| Rendezvous tests | `rendezvous/tests/` | No workflow runs them. |
| Jev review | `.github/workflows/jevlint.yml` | `continue-on-error: true` at line 20. Reads `jevlint.toml` from the base commit at line 26, but the workflow file itself comes from the PR. Model `jev-latest` is a moving alias. |

### What Jev reports

From the upstream [JSON output](https://github.com/INDXDev/jevlint/blob/main/docs/json-output.md) and [scoring](https://github.com/INDXDev/jevlint/blob/main/docs/scoring.md) docs, `jevlint pr --json --intent` prints:

- `files[].findings`: AST findings the change introduced or made worse.
- `files[].answers`: model answers the change lowered, each with `compliance` from 0 to 1.
- `intent`: answers about whether the diff matches the PR title, body, and `AGENTS.md`, in the same shape. Empty when it could not be judged.
- `warnings` and `skipped`: why something was not judged, including provider failures and truncation.

There is no severity field. Upstream states that small score moves are noise, so a score delta is not a usable gate signal.

## Decisions

### D1. Which surfaces get a contract?

| Option | Covers | Cost |
| --- | --- | --- |
| A. Rendezvous only | The highest-skew HTTP surface | Smallest. One spec, two endpoints. |
| B. Rendezvous, then `/v5` | Both live HTTP surfaces | Two specs. `/v5` has nine paths, including multipart and streamed audio. |
| C. B plus `/v4` | Everything over HTTP | Spends effort on a surface that is being replaced. |

**Recommended: B.** Start with rendezvous, because three implementations already share it and nothing checks them against each other. Add `/v5` second. Skip `/v4`.

### D2. Where does the contract come from?

| Option | How | Trade-off |
| --- | --- | --- |
| A. Hand-written OpenAPI 3.1 files | `contracts/rendezvous.yaml`, `contracts/shared-audio-v5.yaml`, reviewed like code | The spec can drift from code, so D3 needs a check. |
| B. Generated from Rust, for example with utoipa | Annotate axum handlers and serde types | The Rust producer becomes the contract. Rendezvous has a TypeScript producer, so it does not fit. A change to the code silently changes the contract, which is the event the gate needs to see. |
| C. Generated from each producer | One generator per language | Two generators, and the contract is still whatever the code says. |

**Recommended: A.** The contract is the thing under review, so it should be a file that changes only when someone means to change it. Generation would make every code change a contract change.

### D3. How is drift detected?

| Option | How | Trade-off |
| --- | --- | --- |
| A. Fixture validation | Shared request and response fixtures under `contracts/fixtures/`. Each implementation's tests decode them, and a schema validator checks them against the spec. | Reuses the pattern in `headless/tests/contracts.rs`. Covers what fixtures cover, not every code path. |
| B. Live conformance | Start each server in tests and validate real responses against the spec | Catches more, but needs a test harness per producer, including the Worker. |
| C. Spec generated and diffed | Generate from code, fail if it differs from the hand-written spec | Rust only, and see D2. |

**Recommended: A, with B later for `/v5` only if fixtures miss a real break.** Fixture tests run PR code, so they belong in `verification.yml`, which has no secrets.

Rendezvous needs one extra step. Its body is an envelope whose `payload` is a signed JSON string. OpenAPI 3.1 can describe the inner shape with `contentMediaType: application/json` and `contentSchema`. Fixture tests must decode `payload` and validate it against that schema explicitly, because a validator treats the outer field as a plain string.

### D4. What counts as breaking?

Run `oasdiff breaking --fail-on ERR` on the base and head specs ([oasdiff breaking changes](https://github.com/oasdiff/oasdiff/blob/main/docs/BREAKING-CHANGES.md)). oasdiff 1.35.0 is the latest release as of 2026-11-07, and it supports OpenAPI 3.1.

- **Blocks**: a removed path or operation, a removed response field, a new required request field, a narrowed type or enum, a tighter limit.
- **Passes**: a new path, an optional request field, an added response field, description and example changes.
- **Intended breaks** go through a new versioned path, as `/v4` to `/v5` did. Otherwise they go through an oasdiff ignore file. A change to that file always goes to a human.

**Verified in S1 (ASO-84).** oasdiff 1.35.0 reports changes inside `contentSchema` as `ERR`, whether the inner schema is inline or a `$ref` to `components`. A removed required response property, a new required request property, and a changed property type each exited 1, with paths such as `payload/contentSchema/expires`. Identical specs exited 0. The rendezvous contract can therefore use either form. The experiment did not cover `const` changes or untyped nested objects.

### D5. What does Jev contribute?

Jev can only add reasons to send a PR to a human. It never approves a breaking change, and it never overrides oasdiff.

A pure `decide` function reads the oasdiff result and `jevlint pr --json --intent`, and returns `pass` or `needs-human` with one reason. It checks in this order, and the first match wins:

1. oasdiff reports `ERR`. The result is `needs-human` with the reason "breaking API change".
2. A contract file changed and the oasdiff input is missing. The result is `needs-human` with the reason "contract not judged".
3. Jev is unavailable. That means `jevlint` exited non-zero or printed nothing that parses as the `pr --json` shape, which covers a missing API key and a crashed CLI. It also means non-empty `warnings`, a contract or API file in `skipped`, an empty `intent`, or a truncated diff. The result is `needs-human` with the reason "review unavailable".
4. Any `intent` answer has `compliance` below the threshold. The result is `needs-human` with the reason "PR description does not match the diff". The default threshold is 0.5, to be tuned from logged data.
5. Otherwise the result is `pass`.

New AST findings and lowered quality answers stay in the summary as advice. They do not change the result, because upstream calls small score moves noise.

Before any Jev input can block a merge, pin a model version in `jevlint.toml` instead of `jev-latest`, and bump the cache prefix.

**Recommended: the order above.** `decide` lives in a small script with unit tests that need no model. A model change then cannot change the rules.

### D6. What does the gate enforce?

| Option | Effect |
| --- | --- |
| A. Required check | The PR cannot merge while the check fails. |
| B. `needs-human` label | The gate labels the PR and posts the reason. A human merges. |
| C. Advisory | The summary only, as today. |

**Recommended: split by signal.** oasdiff `ERR` uses option A after a short advisory period, because it is deterministic and rarely wrong. Jev-derived reasons use option B, because model answers vary between runs. Promote Jev to A only after logged results show it catches real problems.

The owner accepted this split. Agents open many PRs in this repository, as the `agent/aso-*` branches in the merge history show, so the label tells the owner which PRs need a careful read.

### D7. Where does the gate run?

A required check is only as strong as the code that runs it. Under `pull_request`, the PR supplies the workflow file, so a PR can weaken its own gate. Checking out the base commit protects `jevlint.toml`, but not the workflow.

**Recommended: two jobs.**

| Job | Trigger | Secrets | Runs PR code | Does |
| --- | --- | --- | --- | --- |
| `contract-gate` | `pull_request_target`, with `pull-requests: write` for the label | `TYPESAFE_AI_API_KEY` | No | Checks out base. Fetches the PR head ref as data and reads head specs with `git show`. Runs oasdiff, jevlint, and `decide`. Sets the label and the check result. |
| Drift tests | `pull_request` in `verification.yml` | None | Yes | Fixture validation from D3. |

`contract-gate` must never check out the head commit or run a script from it. The current workflow runs `jevlint pr` against a base checkout and gets the PR's changes, so jevlint appears to read them through the GitHub API. S3 confirms this before relying on it.

Under `pull_request_target`, fork and Dependabot PRs would receive the secret, and their file contents would go to TypeSafe AI. Today they get AST-only reviews because they receive no secrets.

**Recommended: keep the AST-only branch for fork and Dependabot PRs.** An AST-only run has an empty `intent`, so D5 rule 3 sends these PRs to a human. That is intended. A PR from an author without a model review needs a human read.

## Delivery slices

Each slice ends in a check that can be rerun. S2 depends on S1, S3 on S2, and S4 to S6 on S3.

| Slice | Issue | Delivers | Done when |
| --- | --- | --- | --- |
| S1 | ASO-84 | oasdiff `contentSchema` experiment | Two specs that differ by one inner property, and the recorded `oasdiff breaking --fail-on ERR` exit code |
| S2 | ASO-85 | Rendezvous contract and fixtures, a rendezvous test job in CI | Drift tests pass in TypeScript and Rust, and a deliberately broken fixture fails both |
| S3 | ASO-86 | `contract-gate` job with oasdiff only, advisory | A test PR that removes a field reports `ERR` in the summary |
| S4 | ASO-87 | `decide` script with Jev input, label output, pinned model | Unit tests cover every rule in D5. A test PR with an empty description gets the label |
| S5 | ASO-88 | `/v5` contract and fixtures | Drift tests pass for `headless/src/client.rs` paths |
| S6 | ASO-89 | Ruleset that requires the oasdiff result | A breaking test PR cannot merge |

## Out of scope

- **Cluster QUIC messages.** Swift reimplements them, so they carry the most skew risk. A contract for them needs a different tool, such as shared JSON fixtures that the Swift and Rust test suites both decode. ASO-90 designs it.
- **Approval by bot.** riskjudge approves PRs. This gate only blocks or labels them. A human still merges.
- **Swift drift tests for rendezvous.** They are added once S2 shows the fixture format holds.
