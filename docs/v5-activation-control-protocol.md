# v5 activation control protocol

Status: Proposed 2026-11-15 for ASO-145. The owner chose the options marked "Chosen" in C1 to C13. Parts 1 to 4 are implemented; part 5 is a design. This document authorizes no production operation.

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

## Part 5: review of a halted journal

Designed for ASO-154. Not implemented.

A journal halts for review in two cases (part 1, with the exceptions stated there for a revoked signer and a settled installation):

- It holds a proposal or a certificate and sees another unresolved proposal, or another certificate, from the same head and epoch. Two certificates of one proposal count: they differ in the prepared acknowledgments they carry.
- It sees a certificate beside an abort of its proposal or beside a host's withdrawal from it.

The envelope that arrived second is stored as a conflict, outside the journal. From then on the host takes in no envelope, signs nothing for a session, refuses writes and release, and reconciles no data with other hosts. It keeps serving its clients what it holds, and it keeps listing and serving the envelopes of its journal to other hosts. Until this part is implemented nothing clears the halt.

Three facts of the current build shape the design:

- Which envelope is the conflict depends on the order of arrival, so two hosts can hold the same two envelopes with the roles exchanged.
- A host does not list or serve its conflicts, and `status` shows only that the journal is halted. A host that never received the second envelope is not halted, and learns nothing about it from a halted peer.
- A coordinator that holds every prepared acknowledgment signs the certificate without asking the hosts again, and a frozen host installs a certificate it holds. A host that is not halted goes on while another is.

### Terms

- A **contest** is everything that descends from one head at one epoch: the proposals a host holds from that head, in its journal or among its conflicts, with their acknowledgments, certificates, withdrawals and aborts.
- A **ruling** is the owner's decision on one contest. It names the head, the epoch, what stands, and what is **void**. What stands is one certificate, named by its own digest, or one proposal without a certificate, or nothing. What is void is a list of proposals and certificates, each by its digest.

### C10. Who clears a halt, and with what evidence?

- **A (chosen 2026-11-17):** the owner, with a command on the stopped host, next to `freeze` and `designate`. The command names every conflict that the host holds for the contest. No signature of a host clears a halt, a coordinator's included.
- **B:** a ruling signed by every host and exchanged between them. It needs a new envelope and an exchange between halted hosts, and it rests on the hosts whose records are in dispute.

### C11. Is a ruling local?

- **A (chosen 2026-11-17):** it is a local record on each host, and hosts compare it. A host shows the digests of its rulings to its peers. While two hosts differ, they reconcile no data and take in no envelope from each other, and no coordinator proposes.
- **B:** local only. A host works again as soon as its own halt is cleared. Two hosts that ruled differently would not notice.

### C12. What can a review decide?

- **A (chosen 2026-11-17):** one proposal of the contest stands, or none does. A certificate that any host installed stands. A void envelope stays as evidence and is never accepted later.
- **B:** always void every proposal and start again. This cannot be used once any host installed a certificate of the contest.

Refined after review: where a certificate exists, the ruling names that certificate and not only its proposal. A certificate that no host installed stands as well, with one exception: beside an abort of its proposal the owner voids the certificate, because every host withdrew and may have been released since.

### C13. Does a halted host take in data while it waits?

- **A (chosen 2026-11-17):** no. Data between hosts stays deferred, as in the table of part 2. The host keeps serving what it holds. This is what D2 of the activation design asks of a forked journal.
- **B:** take in data from hosts at the same installed head. The halt may be about which head is right.

### The principle

A ruling removes the halt and tells a host which envelopes it must never act on. It releases nothing by itself:

- A prepare lock is resolved only as before, by a signed abort or by an installation. This keeps the rule of D6 that locks are released by a signed abort after it is known that no certificate exists.
- A void proposal is taken out through the abort of part 1: every host withdraws, and the proposal's coordinator signs the abort.
- A standing certificate is installed through the installation of part 1, with every check it has.

So a ruling that is wrong, or that only some hosts hold, leaves hosts waiting. Between hosts that follow these rules it does not let two of them install different certificates from one head; the argument is under "Agreement between hosts". A host that reports a ruling it does not hold is outside it, as a false acknowledgment is in D2.

A certificate that is void under the host's ruling is evidence and no more. Every rule of parts 1 and 3 that asks whether a certificate exists for a proposal, such as the refusals to withdraw and to abort and the coordinator's choice to go forward, means an **effective** certificate: one that is not void.

### Procedure

1. The owner stops every host of the membership. A host that cannot be reached and stopped keeps the review waiting: nobody knows what it installs meanwhile.
2. The owner reads the evidence on every host, halted or not.
3. The owner records the same ruling on every host.
4. The owner starts the hosts. They stay frozen.

The build cannot check that all hosts were stopped together. The rules below are made so that a ruling recorded without that fence stalls and does not fork. `release` needs no rule of its own: it is refused while a lock is pending, and a ruling resolves no lock.

### Seeing the evidence

`shared-audio-control status` shows what follows for each head and epoch that has more than one proposal, a conflict or a ruling on this host. With `--contest <head> <epoch>` it shows the same for that head and epoch on any host with control storage, also where the host holds one proposal and its installed certificate and nothing looks wrong:

- each proposal: its digest, coordinator and session, and whether this host prepared it, withdrew from it, or holds its abort;
- each certificate by its own digest, with its proposal, whether it is installed here, and whether it sits in the journal or among the conflicts. Certificates below the installed head are included;
- each conflict: its digest, its kind, the host that signed it and the reason it was stored;
- the ruling and its digest.

The union of what the hosts show is the contest. A host that is not halted takes part: it may hold a certificate or an installation that decides the ruling.

### The command

`shared-audio-control rule` runs on the stopped host and takes:

- the head and the epoch of the contest;
- `--stands-certificate <digest>`, `--stands-proposal <digest>` or `--none-stands`;
- `--void <digest>` for every other proposal and certificate of the contest that the owner found on any host;
- `--reviewed <digest>` for every conflict this host holds for the contest.

It is refused:

- when this host holds a proposal, a certificate or a conflict of the contest that the command names nowhere. The owner cannot clear what they have not seen;
- when a digest appears twice among what stands and what is void, or what this host holds under a digest is not of the stated kind, head and epoch. A reviewed conflict is also named as standing or void;
- when a void certificate, or a certificate of a void proposal, is installed on this host. Installed state is not undone by a ruling;
- when `--stands-proposal` names a proposal for which this host holds an abort or a certificate. An aborted proposal is resolved already, and a certified one stands by its certificate.

A host that holds none of the named envelopes accepts the command. A host that holds the abort of a proposal and not its certificate accepts `--stands-certificate` for it; it fetches the certificate afterwards.

The command prints the digest of the ruling, and takes `--expect <digest>` so that the owner can require on the next host what the first one printed.

A host holds one ruling for a contest. Recording another one replaces it, under the same refusals and one more: the new ruling names every digest the old one named, as standing or void. A ruling is never removed. This is also how a ruling is extended when a further envelope turns up. Every recording, also of a ruling with a digest the host held before, discards what the host has seen of its peers' rulings.

### What a ruling does

Recording:

- In one transaction the host stores the ruling and moves the conflicts it names into the journal. The standing certificate becomes an ordinary certificate with the proposal it carries. A void envelope is kept and marked void.
- The journal is halted while it holds a conflict that no ruling names. The consistency check of the journal reads void envelopes as evidence: they are verified, and they neither count as rivals nor contradict what stands.
- The digest of a ruling is taken over canonical bytes like those of an envelope: a label and version of its own, the cluster, the head, the epoch, what stands with its kind, and the void entries, each with its kind, sorted. It does not cover the reviewed conflicts, which differ between hosts.
- A host can accept a ruling for a digest it does not hold. When an envelope with that digest arrives later and is not of the kind, head and epoch the ruling states, it is refused.
- A ruling carries the owner's authority for the envelopes it names, whatever session they name. The designation of the host does not change.

A void proposal:

- The host does not prepare it, and neither records nor installs a certificate for it. Such a certificate is refused without halting.
- The host lists and serves the void proposal, and takes it in from a peer with the same ruling, so that every host can withdraw from it. A void certificate is neither listed nor served.
- While frozen, the host signs its withdrawal from it, and takes in the withdrawals and the abort of it, whatever session the proposal names.
- Its lock, if this host prepared it, stays pending until the abort is stored, or until a certificate from the same head is installed here. After that installation nothing can follow the old head, so the other proposals from it no longer count as pending, neither by this host's lock nor by the acknowledgments of other hosts that it stores.
- The host that signed the void proposal signs its abort once it holds a withdrawal from every host of the proposal. It does so as a reaction to the ruling, while frozen, without a request and whatever session it is designated for. It collects the withdrawals through the ordinary exchange.
- It does not conflict with what stands or with another void proposal. Towards anything the ruling does not name it is an unresolved proposal until its abort is stored, so a new proposal from the same head waits for the abort, as in part 1.

A void certificate is never installed. It is refused without halting when a peer offers it again, also when its proposal stands with another certificate.

A standing certificate:

- A host installs it only after it has seen the same ruling on every host of every proposal the ruling names, standing or void, in an exchange since it last recorded the ruling. The host stores which hosts it has seen. This is the barrier against a host that was not stopped, not ruled, or ruled differently.
- Installation keeps the checks of part 1: the freeze, the ancestry, the profile floor, the membership rules of C2, and the input history that this host acknowledged. A host that was released after an abort and took in data since cannot install it. Then no ruling helps and D6 applies.
- The session is the exception. A standing certificate is installed whatever session it names, on the ruling's authority, and its installation acknowledgments are taken in the same way.
- For that certificate alone, an abort of its proposal and the withdrawals from it are void, this host's own withdrawal included, whether it was signed in a session or under an earlier ruling. This is the one case where the owner's ruling overrides a host's signed promise. The barrier above, not the withdrawal, is what keeps two hosts from installing differently.

A standing proposal without a certificate goes on as before the halt. Its coordinator signs the certificate only when every host of the proposal answered in the same pass with the same ruling.

Envelopes the ruling does not name follow part 1 again. The withdrawals and the abort of a void proposal, the acknowledgments and the certificate of a standing proposal, and the installation acknowledgments of a standing certificate are recorded. A second certificate of the standing proposal, or a proposal that meets an unresolved one, halts the journal again, and the owner extends the ruling.

### Agreement between hosts

- The summary of part 2 gains the digests of the host's rulings.
- Two hosts whose digests differ treat each other as halted: data is deferred, and neither takes in envelopes from the other.
- The coordinator proposes only when every host of the membership answered in the same pass with the same rulings as its own (part 3, one pass, step 1).
- No two hosts that follow these rules install different certificates of one contest. Suppose X installs C1 under ruling R1 and Y installs C2 under R2, and each ruling names both certificates. A replacement keeps every name, so a host that was once told of both cannot be ruled as if it knew only one. X saw Y show R1 after X last recorded R1, and held R1 from then on. Y saw X show R2 after Y last recorded R2, and held R2 from then on. So X showed R2 before it recorded R1, and Y showed R1 before it recorded R2, and each of those came after the other's recording. That is a cycle in time. A host that installs without any ruling is covered too: it then refuses every ruling that voids its certificate, so the others never see it agree.
- Equal digests show that two hosts were told the same. They do not show that a host kept its ruling: a host restored from an earlier backup shows the digests it had then. Restoring stays under D6 and D7.
- A build from before this part rejects a summary with a field it does not know, so its exchange fails and data is deferred. Every host needs a build with this part before a ruling leads to agreement.

### What the owner decides, by case

First, every certificate that no host installed and whose proposal has an abort on some host is void. Among what remains, the first row that matches applies.

| Evidence across all hosts | Ruling |
| --- | --- |
| Two different certificates of the contest are each installed on some host | None. See below |
| One certificate is installed on some host | That certificate stands. Every other proposal and certificate is void |
| One or more certificates, installed nowhere | The owner lets one certificate stand. The others are void |
| Proposals only, or nothing | Nothing stands, and a new session follows once the aborts are stored. One proposal may stand instead if it is unresolved on every host |

A certificate can stand beside withdrawals from its proposal, installed or not. Beside an abort it stands only when a host installed it.

When two certificates from one head are installed on different hosts, the cluster is forked and no ruling is accepted on every host. D6 decides what follows: forward repair once any host wrote under the new epoch, a coordinated restore only before that. Neither procedure is defined in this document.

Two unresolved proposals from one head, or a certificate signed after a withdrawal, are what a correct build does not produce. An aborted proposal followed by a new one from the same head is ordinary. The ruling does not judge a host. Revoking or isolating it is the owner's separate decision under D3, and a ruling waives no membership check.

### Waiting

A ruling does not help where the protocol already waits:

- A void proposal whose signer does not sign the abort keeps its locks. This is the unreachable host of part 1.
- A host that is offline shows no ruling, so no standing certificate is installed and no coordinator proposes.

### What a ruling does not do

- It does not repair a journal that cannot be read. That journal stays in review.
- It does not prove that the owner read the same evidence on every host.
- It does not undo an installation, restore data, or revoke a host.
- It does not release a prepare lock or the freeze.

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
- Recovery when a coordinator lost its journal and aborted while a certificate exists elsewhere. The hosts detect the contradiction and halt for review; part 5 describes the ruling.
- A host restored from a backup that still holds a freeze, a designation and a proposal. It reacts as after an ordinary restart, and learns of a later withdrawal, abort or release only when a peer returns it. Restoring is governed by D6 and D7 of the activation design and by the startup guard.
- Implementing the review of a halted journal (part 5).
- Recovery of a journal that cannot be read, and the repair or restore after two installed certificates from one head (D6 of the activation design).
- A relay path between v5 hosts. A host that is reachable neither by discovery nor at a given address keeps the coordinator waiting (C7).
- A live view of the coordinator's progress. It is logged; `status` reads the journal of a stopped host.
