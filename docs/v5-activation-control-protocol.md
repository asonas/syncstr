# v5 activation control protocol

Status: Proposed 2026-11-15 for ASO-145. The owner chose the options marked "Chosen" in C1 to C3. Part 1 is implemented; parts 2 and 3 are design only and each needs its own review. This document authorizes no production operation.

This document refines slice S3 of the [activation and recovery design](v5-activation-and-recovery.md), decisions D1 to D3 and the failure table in D6. It covers how hosts exchange the control journal, how a coordinator collects readiness from every authorized host, and how an activation that cannot finish is resolved. The local journal and the maintenance freeze are described in the [headless guide](../headless/README.md#maintenance-freeze-on-a-v5-host).

## Decisions

### C1. How does a host learn which coordinator to trust?

- **A (chosen):** the owner records the maintenance session on every host: the coordinator's host key and a session nonce. This is a command on the stopped host, next to `freeze`. A host answers control requests automatically only for a proposal that names that coordinator and nonce.
- **B:** only the coordinator knows the session, and a frozen host accepts a proposal from any authorized host. One compromised host key could then start an activation.

Consequence: the owner touches every host once per maintenance session. Releasing the freeze removes the designation, so the next session needs a new one.

### C2. What happens when membership changes after a certificate exists?

- **A (chosen):** a host may store and install a certificate for a proposal it prepared, even if its membership changed afterwards. It proved the proposal's membership revision when it took the prepare lock, and the certificate carries that acknowledgment. Release still requires the current membership to equal the certified one, so the host stays frozen until a later epoch certifies the new membership. A revocation takes effect immediately.
- **B:** stop merging membership learned from peers between the prepare lock and the last installation. Nothing else changes, but a revocation is delayed for the whole maintenance session.
- **C:** leave the hosts stuck and resolve each case by hand.

The next epoch needs every installation acknowledgment of the installed one, with one exception: a host that the next proposal's membership no longer authorizes. Grants are never deleted, so a host missing from the new host list is revoked in that revision.

### C3. Delivery

Chosen: three parts.

1. Local journal changes: session designation, signed abort, input history and the intake pin, and the C2 rules. No network code.
2. The control protocol between hosts, and control-first synchronization.
3. The coordinator that drives a session.

## Part 1: journal rules

### Session designation

`designate` records the coordinator and nonce. The coordinator must be an authorized host in the host's current membership. A different session cannot replace the recorded one while a preparation or certificate is pending.

Part 1 only stores the designation. The journal operations still take the expected session from their caller; part 2 passes the stored one.

### Input history

The input history of a host is a SHA-256 digest over the sorted identifiers of its signed music records and its signed playlist records, with a domain prefix. Membership is not part of it; the membership revision covers that.

- A host signs a prepared acknowledgment only for its own current input history.
- From its prepare lock until the proposal is installed or aborted, a host refuses replicated pages that contain a record it does not hold. A stored certificate that is not installed has the same effect. Records it already holds, audio bytes and membership still replicate.
- Installation checks the input history again against the certificate.
- After installation no host accepts writes until it is released, and release needs every installation acknowledgment, so nothing new can arrive in between.

All hosts are frozen while a proposal is prepared, so a refused record existed before the freeze on a host that had not finished replicating. The acknowledged histories then differ, no certificate can form, and the proposal is aborted. The coordinator compares histories before proposing to avoid this.

### Membership changes

| When | Outcome |
| --- | --- |
| Before a host takes its prepare lock | The host refuses to prepare. The proposal cannot be certified and is aborted. |
| After a prepare lock, before a certificate | The host keeps its lock. Signing a pending acknowledgment is refused. A coordinator that knows of the change aborts instead of certifying. |
| After a certificate exists | C2: hosts that prepared install it and acknowledge. Release is refused. A later epoch certifies the new membership. |

### Signed abort

Two envelopes are added to the journal.

| Envelope | Signed content |
| --- | --- |
| Withdrawal | Proposal digest and the host. The host holds no certificate for the proposal and will never prepare, store or install one. |
| Abort | Proposal digest, one withdrawal from every host of the proposal, and the coordinator. |

Rules:

- A host records its withdrawal durably in the same transaction that stores the signed envelope. A host that holds a certificate for the proposal refuses to withdraw.
- After withdrawing, a host refuses to take a prepare lock for the proposal.
- An abort is valid only with a withdrawal from every host in the proposal's host set, signed by the proposal's coordinator.
- Storing an abort resolves the proposal: its prepare lock stays as evidence but no longer blocks release, no longer pins the input history, and no longer raises the profile floor. A profile floor comes only from installed certificates and unresolved locks.
- An aborted proposal is not a sibling. A new proposal from the same head and epoch can be recorded and prepared after the abort. Two unresolved proposals from one head still halt the journal.
- A host's own signed withdrawal binds it however the envelope arrives, so a host restored to an earlier state keeps its promise once a peer returns the envelope.
- A certificate cannot stand beside an abort of its proposal or beside any host's withdrawal from it. Whichever arrives second is recorded as a conflict and halts the journal for review. A certificate or an abort halts even if its signer was revoked since, because it carries every host's signature. A withdrawal from a host that is revoked locally is refused instead, so one revoked host cannot halt the others. This check runs before the sibling check, so a retry recorded after an abort does not turn the aborted proposal's certificate into a mere rival.
- A signature carries no time. A withdrawal is therefore refused, without halting, when its certificate is installed here and either the withdrawing host's installation acknowledgment is stored or a later epoch is installed. One host cannot halt the others over a settled epoch. A withdrawal still halts while the certificate is stored but not installed, or installed without that host's acknowledgment.
- A membership that cannot be read or verified is an error, not a membership change; the C2 rule applies only to a verified, different revision.
- An unreachable host means the abort waits.

The coordinator's order matters. It first synchronizes control records with every host. If any host holds a certificate, the session goes forward: the certificate is installed everywhere. Only when no host holds one does the coordinator withdraw itself, and after that it must not sign a certificate for the proposal.

## Part 2: control protocol (design)

- Hosts speak a separate protocol, negotiated as its own ALPN (`syncstr/control/1`), on the existing cluster endpoint. The data protocol and its strict request decoding do not change. A host that does not offer the protocol has unknown readiness.
- Both sides present their membership proof as in the data protocol and must authorize each other as hosts.
- The opening message carries a journal summary: epoch, head, freeze and release state, halt state, session nonce, membership revision, input history, and the identifiers of stored envelopes.
- Requests: fetch envelopes by identifier together with the membership snapshot of their proposal; offer envelopes; ask for a prepared acknowledgment, an installation acknowledgment, or a withdrawal. The three signing requests are answered only for the designated session.
- Control first: a host with a control journal exchanges control records with a host peer before it reconciles data with that peer. It reconciles data only when both have the same installed head. A peer without the control protocol is reconciled only while the local journal has no head and nothing pending.

Message shapes are fixed with byte or JSON vectors when this part is implemented.

## Part 3: coordinator (design)

The owner starts a session on the designated coordinator with the required profiles and the inventory and backup manifest digests. The coordinator then advances on its own and reports why it waits.

1. Reach every host in the membership's host set over the control protocol. Any unreachable, unknown or disputed host blocks. The set is never reduced to the hosts that answer.
2. Require every host to be frozen, designated for this session, at the same head, membership revision and input history.
3. Sign and offer the proposal. Collect a prepared acknowledgment from every host.
4. Sign the certificate, store it, offer it to every host, and collect installation acknowledgments. Offer every acknowledgment to every host.
5. Report completion. Release stays a separate command on each host.

The owner may ask the coordinator to abort a proposal that has no certificate. It follows the order in "Signed abort".

## Done-when mapping for ASO-145

| Criterion | Where |
| --- | --- |
| An offline, unknown or disputed host blocks | Part 3, steps 1 and 3; certificate verification already requires every host |
| A grant or revocation during preparation invalidates the proposal | Part 1, membership changes |
| A returning host synchronizes control state first | Part 2, control first |
| No intake that changes an acknowledged input history | Part 1, input history |
| A signed abort releases locks only without a certificate | Part 1, signed abort; part 3 for collection |
| A partly stored certificate is installed everywhere before release | Existing release rules, C2, and part 3, step 4 |

## Not covered

- The startup guard (ASO-146) and journaled enrollment or promotion (ASO-147).
- Excluding a host that cannot return. D3 of the activation design requires isolation in addition to revocation.
- Recovery when a coordinator lost its journal and aborted while a certificate exists elsewhere. The hosts detect the contradiction and halt for review.
