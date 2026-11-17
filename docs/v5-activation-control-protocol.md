# v5 activation control protocol

Status: Proposed 2026-11-15 for ASO-145. The owner chose the options marked "Chosen" in C1 to C9. Parts 1 to 4 are implemented. This document authorizes no production operation.

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

## Part 2: control protocol

Implemented.

### C4. A peer without the control protocol

- **A (chosen 2026-11-15):** such a peer reconciles data only while this host has no installed head and nothing pending. Pending means a prepare lock this host holds, a prepared acknowledgment it stored from another host, or a stored certificate. A recorded proposal that no host has prepared is not pending: no host has acknowledged an input history yet, and the hosts still have to converge before they prepare.
- **B:** refuse it as soon as this host has a control journal. Stricter, but `init` could not run until every host was upgraded.

### Transport

- Hosts speak a separate protocol, negotiated as its own ALPN (`syncstr/control/1`), on the existing cluster endpoint. The data protocol's requests and their strict decoding do not change.
- A host that serves it says so in its data protocol reply, in the optional field `"host_protocols": ["syncstr/control/1"]`. The reply is sent after both sides authenticated, so a peer can rely on it. Members and older hosts ignore the field.
- Messages are length-prefixed JSON frames, as in the data protocol. Unknown fields are refused. Digests and keys are arrays of byte values; canonical envelope bytes are hexadecimal text.
- The client opens with `{"version": 1, "proof": <membership proof>}`. The server merges the proof as the data protocol does, requires the client to be an authorized host, and answers `{"version": 1, "proof": ..., "journal": ...}`. The client merges the server's proof and requires both sides to be authorized hosts.
- `journal` is `{"state": "absent"}` for a host that never initialized control storage, `{"state": "unreadable"}` for a journal that needs review, or `{"state": "readable", "summary": {...}}`.
- The summary carries `epoch`, `head`, `frozen`, `released`, `halted`, `pending`, the designated `session`, the `membership` revision (null while it cannot be verified), `input_history`, and the identifiers of the stored `envelopes`.
- One request exists: `{"operation": "fetch", "envelopes": [<identifier>, ...]}` with at most 32 identifiers. The answer lists each envelope the server holds as `{"canonical": <hex>, "membership": <index>}` and the membership snapshots the indexes refer to. The server authorizes both hosts again for every request. An answer stops growing at about 16 MiB, and an envelope that alone needs more is not served. What an answer leaves out is fetched on a later exchange.
- A later version of this protocol is offered as another ALPN next to this one, because unknown fields are refused.

Nothing is signed in answer to a request. Envelopes move by fetching, so every step can be repeated after a crash.

### Taking in envelopes

- A host fetches the envelopes a peer lists and it does not hold, and records them with the journal operations under the session the owner designated on it. Without a designation, or with a halted, unreadable or absent journal, it records nothing. An envelope for another session is refused.
- Envelopes are recorded in dependency order: proposals, prepared acknowledgments, withdrawals, aborts, certificates, installation acknowledgments.
- Each answer is recorded before the next is fetched, so an exchange that is cut short keeps what it brought.
- A refused envelope is fetched again only after this host's journal changed.

### Control first

Before a host reconciles data with a peer it exchanges control records with that peer. Data follows only when the journals agree:

| This host | Peer | Data |
| --- | --- | --- |
| No control journal | Any | Reconciles as before |
| Readable | Readable, same installed head | Reconciles |
| Readable | Readable, another head | Deferred |
| Readable, no head, nothing pending | No journal, or does not list the control protocol | Reconciles (C4) |
| Readable, with a head or anything pending | No journal, or does not list the control protocol | Deferred (C4) |
| Readable | Unreadable | Deferred |
| Readable | Lists the control protocol, but the exchange failed | Deferred |
| Halted on either side | Any | Deferred |
| Unreadable | Any | Deferred |

A host opens the data session first and reads `host_protocols` from the authenticated reply. A peer that lists the control protocol must complete the exchange: a timeout, a refused connection, a broken answer or a refused authorization leaves its journal unknown and defers data. Only a peer that does not list it counts as having no journal. A connection error is never taken as evidence, because it can arrive before the peer is authenticated.

Replication is pulled by the receiving host, so each host applies this before it reads from a peer. The data protocol also lets a host push records. A pushing host cannot show its journal there, so a push is accepted only where a peer without a journal would be: by a host with no control journal, or with no head and nothing pending.

The check runs once before the data session, so a peer can install the next head while this host still reads its pages. That is harmless: a host signs no new record until it is released, release needs the installation acknowledgment of every host the head authorizes, and a host acknowledges only after it installed. Until this host installed, the peer has nothing newer to give; a host the head no longer authorizes is refused by the data protocol itself.

### C5. When does a host sign on its own?

- **A (chosen 2026-11-15):** freezing the host and designating the session is the owner's consent. A frozen host reacts to records of its designated session without another step.
- **B:** a separate switch on every host before it reacts. One more guard against a wrong designation, and one more step on every host.

### Host reactions

The earlier draft had the coordinator ask each host for its signatures. Instead each host reacts to what it holds after every synchronization pass, for its designated session only:

- The proposal's coordinator withdrew from it and this host holds no certificate for it: this host withdraws, and does not prepare it.
- It holds a certificate that is not installed, or an installed head whose acknowledgment it never stored: while frozen, it installs it and signs its installation acknowledgment.
- It holds a proposal that extends the installed head and has not acknowledged it: while frozen, it takes the prepare lock and signs its prepared acknowledgment for its current input history.

The coordinator and the other hosts then fetch those envelopes like any other.

- A host that is not frozen takes none of these steps, a withdrawal included.
- Every step goes through the journal operation of the same name, whose rules still apply. Two conditions are the reaction's own: it requires the freeze for a withdrawal, and it does not prepare a proposal its coordinator withdrew from. A step that is refused is reported and tried again after the next exchange.
- Records are taken in and answered by the same loop, one peer at a time, so no record arrives between a plan and its steps.
- A host without a designation, with a halted or unreadable journal, or whose identity is not the host the journal's local grant names, does nothing.
- In its prepared acknowledgment a host names its build as its implementation and lists the profiles the build implements. No profile is bound to an implementation yet, so a proposal that requires one is not prepared by a serving host; binding the first profile is slice S4 of the activation design.
- A host prepares as soon as it holds the proposal. If the hosts' input histories differ at that moment no certificate can form and the proposal is aborted, so the coordinator compares histories before it proposes (part 3).

## Part 3: coordinator

Implemented.

### C6. How does the owner instruct a serving coordinator?

- **A (chosen 2026-11-15):** a command on the stopped coordinator records a request, next to `freeze` and `designate`: `start` with the required profiles and the inventory and backup manifest digests, or `abort`. The serving host carries the request out. No request that makes a host sign arrives over the network. Asking for an abort means restarting the coordinator.
- **B:** an administrative route on the serving host. No restart, and whoever holds the API token could start an activation.

### C7. A host that discovery does not report

- **A (chosen 2026-11-15):** the coordinator waits and names the host. Static addresses for `shared-audio-serve` also change data synchronization and are a separate change.
- **B:** add static peer addresses with the coordinator.

That separate change (ASO-155) gave `shared-audio-serve` the option `--peer-address ID=ADDRESS_FILE`. The owner names the address file another host wrote. The address is added to what discovery reports, and the host passes the same membership check, control exchange and data gate. The coordinator still waits for a host it has no address for. The v5 endpoint uses no relay, so a given address must be reachable directly.

### The request

A request holds the profiles, the two manifest digests, the proposal signed for it and whether an abort was asked for. It belongs to the designated session: `start` is refused unless the host is frozen and its local grant is the designated coordinator's, and designating another session or releasing the host deletes it. A new request replaces one that signed nothing yet, or whose proposal is aborted or installed on this host.

### One pass

After every synchronization pass the coordinator looks at its journal and at what each host showed in that pass, and signs at most one record. It reports each step and each reason for waiting once.

1. Without a proposal: every host of the current membership must have answered in this pass with a readable journal that is not halted, frozen, designated for this session, and at the same installed head, epoch, membership revision and input history. The installed head must hold the installation acknowledgment of every host the membership still authorizes. Then the coordinator signs the proposal and records it in the same transaction that binds it to the request. An earlier answer does not count, and the set is never reduced to the hosts that answer.
2. With a proposal and a prepared acknowledgment from every host: it signs the certificate and stores it in one transaction. It refuses after a membership change and after any host's withdrawal; the report then asks for an abort.
3. With a certificate: it waits for its own installation and for every installation acknowledgment, then reports completion. Release stays a separate command on each host.

Prepared acknowledgments, the certificate and installation acknowledgments reach the other hosts by fetching, as every record does.

The coordinator compares what each host showed when its exchange began. A host can still change before it prepares; the journal rules decide then, as described under "Input history".

### Abort

`abort` on a request without a proposal deletes the request: nothing was signed. `abort` is refused once the coordinator holds a certificate. Otherwise the coordinator follows the order in "Signed abort":

1. Every other host of the proposal must have answered in this pass with a readable journal that is not halted, and must list no record that this host lacks and has not seen to be something else than a certificate. A halted host keeps the record that contradicted its journal apart from the ones it lists, so it may hold a certificate. A certificate that could be taken in moves the session forward instead. One that could not be keeps the coordinator from withdrawing, and waits for review.
2. It signs its withdrawal. Withdrawing is refused once a certificate is stored, and signing a certificate is refused once any host withdrew. Each commits with its check, so the coordinator cannot do both.
3. The other hosts follow its withdrawal as a reaction. With a withdrawal from every host it signs the abort.

A proposal is identified by its content. The same request under the same session produces the aborted proposal again, so a retry needs a new session. Once every host holds the abort nothing is pending, and the owner designates another nonce on every host. The hosts can stay frozen; after a membership change behind an installed certificate they cannot be released before the next epoch (C2).

## Part 4: startup guard

D3 of the activation design asks for a guard that a build unaware of the profile floor cannot ignore (ASO-146).

### C8. Where does the marker live?

- **A (chosen 2026-11-17):** the schema generation of the host database, `PRAGMA user_version`. Every build since the first v5 one opens a shared store only when it is exactly 5, and the legacy store opens nothing above 4. Generation 6 therefore stops all of them by their own check, also when the executable is started directly. A restored copy of the data carries the marker with it.
- **B:** a marker file and a launcher that checks it, as the activation design first said. An old binary started directly ignores both, so the service configuration of every platform would have to prevent that.

### C9. When is the marker raised?

- **A (chosen 2026-11-17):** when control storage is initialized (`shared-audio-control init`), in the same transaction. A build before the control journal knows neither the freeze nor the designation, and would accept writes on a frozen store.
- **B:** when the profile floor first becomes non-empty. An earlier build could still open a frozen store.

### Rules

- `init` raises the generation to 6. It never goes back: returning to an earlier build means restoring a backup taken before `init`, under D6 of the activation design.
- A store at a generation above 6 is refused by this build, so a later marker can fence it the same way.
- Before `shared-audio-serve` opens its endpoint or its listener it checks the store:
  - Without control storage the generation must be 5, and the host serves as before.
  - With control storage the generation must be 6. Control storage written by a build before the marker is refused until `init` runs again.
  - Every profile of the stored floor must be implemented by this build. The floor holds the profiles of installed certificates and of unresolved prepare locks, so a host that prepared a proposal does not come back on a build without its profiles.
- The guard reads the stored floor, not the whole journal. A halted journal does not stop a host from serving what it holds; it refuses writes itself. A state row that cannot be read stops the host, because its floor is unknown.
- The other commands of `shared-audio-control` stay available below the floor, so the owner can inspect the host. They open the store like every command, so a generation above 6 refuses them too.
- `shared-audio-activate` on a marked store keeps generation 6 and reports it. It still checks the baseline and changes nothing.
- The inventory reads generation 6 as an activated store. The comparison keeps the generation as a category: reports of a host at 5 and a host at 6 block with `divergence:schema`. The owner runs `init` on every host before taking the inventories that a request names.
- The guard is a rule of the `shared-audio-serve` command. The library functions that serve do not call it themselves.

### What the marker does not do

- It does not stop a build that deliberately ignores the generation. A host acknowledgment remains an assertion by a trusted host; operators verify installed builds separately (D2 of the activation design).
- It does not cover a data directory restored from before `init`. Such a restore is a downgrade under D6.
- It does not compare the floor between hosts. Admission of a host at the active floor is ASO-147.

Evidence that earlier builds refuse a marked store is in the [validation record](validation/v5-startup-guard.md).

## Done-when mapping for ASO-145

| Criterion | Where |
| --- | --- |
| An offline, unknown or disputed host blocks | Part 3, one pass, steps 1 and 2; certificate verification already requires every host |
| A grant or revocation during preparation invalidates the proposal | Part 1, membership changes |
| A returning host synchronizes control state first | Part 2, control first |
| No intake that changes an acknowledged input history | Part 1, input history |
| A signed abort releases locks only without a certificate | Part 1, signed abort; part 3, abort |
| A partly stored certificate is installed everywhere before release | Existing release rules, C2, and part 3, one pass, step 3 |

## Not covered

- Journaled enrollment or promotion (ASO-147).
- Excluding a host that cannot return. D3 of the activation design requires isolation in addition to revocation.
- Recovery when a coordinator lost its journal and aborted while a certificate exists elsewhere. The hosts detect the contradiction and halt for review.
- A host restored from a backup that still holds a freeze, a designation and a proposal. It reacts as after an ordinary restart, and learns of a later withdrawal, abort or release only when a peer returns it. Restoring is governed by D6 and D7 of the activation design and by the startup guard.
- Review and recovery of a halted journal (ASO-154).
- A relay path between v5 hosts. A host that is reachable neither by discovery nor at a given address keeps the coordinator waiting (C7).
- A live view of the coordinator's progress. It is logged; `status` reads the journal of a stopped host.
