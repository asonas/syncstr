//! Durable maintenance freeze, session designation and writer release. Local
//! state only; nothing is sent.
use super::*;
use rusqlite::{Connection, OptionalExtension as _, params};

/// Why this host refuses to sign new shared state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    Maintenance,
    Review,
}

impl Refusal {
    /// The reason reported to members in a deferred mutation reply.
    pub fn reason(self) -> &'static str {
        match self {
            Self::Maintenance => "maintenance-freeze",
            Self::Review => "control-review-required",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Maintenance => "host is frozen for activation maintenance",
            Self::Review => "activation control journal requires review",
        })
    }
}

impl std::error::Error for Refusal {}

pub(super) fn exists(db: &Connection, table: &str) -> anyhow::Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)",
        [table],
        |r| r.get(0),
    )?)
}

pub(super) fn tables(db: &Connection) -> anyhow::Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS activation_control_freeze (singleton INTEGER PRIMARY KEY CHECK(singleton=1));
        CREATE TABLE IF NOT EXISTS activation_control_releases (certificate BLOB PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS activation_control_withdrawals (proposal BLOB PRIMARY KEY, statement BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS activation_control_session (singleton INTEGER PRIMARY KEY CHECK(singleton=1), coordinator BLOB NOT NULL, grant_id BLOB NOT NULL, nonce BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS activation_control_request (singleton INTEGER PRIMARY KEY CHECK(singleton=1), profiles BLOB NOT NULL, inventory BLOB NOT NULL, backup BLOB NOT NULL, proposal BLOB, abort INTEGER NOT NULL);")?;
    Ok(())
}

pub(super) fn designated(db: &Connection) -> anyhow::Result<Option<Session>> {
    if !exists(db, "activation_control_session")? {
        return Ok(None);
    }
    let row: Option<(Vec<u8>, Vec<u8>, Vec<u8>)> = db
        .query_row(
            "SELECT coordinator, grant_id, nonce FROM activation_control_session",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    row.map(|(key, grant, nonce)| {
        Ok(Session {
            coordinator: Host {
                key: journal::array(key)?,
                grant: journal::array(grant)?,
            },
            nonce: journal::array(nonce)?,
        })
    })
    .transpose()
}

fn authorized_hosts(db: &Connection) -> anyhow::Result<Vec<Host>> {
    let cluster = journal::state(db)?.cluster;
    Ok(membership_revision(cluster, &crate::enrollment::read_proof(db)?)?.1)
}

/// Storage initialized before these tables existed has never been frozen.
pub(super) fn frozen(db: &Connection) -> anyhow::Result<bool> {
    if !exists(db, "activation_control_freeze")? {
        return Ok(false);
    }
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM activation_control_freeze)",
        [],
        |r| r.get(0),
    )?)
}

pub(super) fn released(db: &Connection, head: &Digest) -> anyhow::Result<bool> {
    if !exists(db, "activation_control_releases")? {
        return Ok(false);
    }
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM activation_control_releases WHERE certificate=?)",
        [head.as_slice()],
        |r| r.get(0),
    )?)
}

/// Call inside the transaction that signs, so a prepare lock cannot commit
/// between this check and the write. A host without control storage has not
/// started activation and keeps accepting writes.
pub(crate) fn ensure_writable(db: &Connection) -> anyhow::Result<()> {
    if !exists(db, "activation_control_state")? {
        return Ok(());
    }
    let inspection = journal::inspect(db).map_err(|_| Refusal::Review)?;
    ensure!(!inspection.halted, Refusal::Review);
    ensure!(!inspection.frozen, Refusal::Maintenance);
    Ok(())
}

impl crate::shared_audio::Store {
    /// Freezing is allowed in any journal state, including halted or corrupt.
    pub fn control_freeze(&self) -> anyhow::Result<()> {
        self.run(|db, _| {
            let tx = db.transaction()?;
            ensure!(
                exists(&tx, "activation_control_state")?,
                "control storage is not initialized"
            );
            tables(&tx)?;
            tx.execute(
                "INSERT OR IGNORE INTO activation_control_freeze VALUES (1)",
                [],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    /// Record the maintenance session the owner authorized on this host: the
    /// coordinator and its session nonce. A pending activation keeps its session.
    pub fn control_designate(&self, session: &Session) -> anyhow::Result<()> {
        self.run(|db, _| {
            let tx = db.transaction()?;
            ensure!(
                exists(&tx, "activation_control_state")?,
                "control storage is not initialized"
            );
            tables(&tx)?;
            let inspection = journal::inspect(&tx)?;
            let unchanged = designated(&tx)?.is_some_and(|current| {
                current.coordinator == session.coordinator && current.nonce == session.nonce
            });
            ensure!(
                unchanged
                    || (inspection.pending_preparations.is_empty()
                        && inspection.pending_certificates.is_empty()),
                "a pending activation belongs to the designated session"
            );
            ensure!(
                authorized_hosts(&tx)?.contains(&session.coordinator),
                "coordinator is not an authorized host"
            );
            if !unchanged {
                // A request belongs to the session it was recorded under.
                tx.execute("DELETE FROM activation_control_request", [])?;
            }
            tx.execute(
                "INSERT OR REPLACE INTO activation_control_session VALUES (1, ?, ?, ?)",
                params![
                    session.coordinator.key.as_slice(),
                    session.coordinator.grant.as_slice(),
                    session.nonce.as_slice()
                ],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    /// The session designated on this host, if any.
    pub fn control_session(&self) -> anyhow::Result<Option<Session>> {
        self.run(|db, _| designated(db))
    }

    /// The authorized host with this key in the current membership.
    pub fn control_host(&self, key: Key) -> anyhow::Result<Host> {
        self.run(|db, _| {
            let mut found = authorized_hosts(db)?.into_iter().filter(|h| h.key == key);
            let host = found.next();
            ensure!(found.next().is_none(), "host key has more than one grant");
            host.ok_or_else(|| anyhow::anyhow!("not an authorized host"))
        })
    }

    /// Release writers only when nothing is pending. With an installed head,
    /// the release is recorded against it so a restart cannot release early.
    pub fn control_release(&self) -> anyhow::Result<()> {
        self.run(|db, _| {
            let tx = db.transaction()?;
            let inspection = journal::inspect(&tx)?;
            ensure!(!inspection.halted, "control journal halted for review");
            ensure!(inspection.frozen, "host is not frozen");
            ensure!(
                inspection.pending_preparations.is_empty()
                    && inspection.pending_certificates.is_empty(),
                "activation is still pending; retain the freeze"
            );
            if let Some(head) = inspection.head {
                ensure!(
                    inspection.all_installations_recorded,
                    "installation acknowledgments are incomplete"
                );
                // Membership learned from peers after installation was never
                // agreed by the certified host set; it needs a new proposal.
                let installed = journal::get(&tx, &head)?;
                journal::current_membership(&tx, proposal(&certificate(&installed)?.proposal)?)?;
                tx.execute(
                    "INSERT OR IGNORE INTO activation_control_releases VALUES (?)",
                    [head.as_slice()],
                )?;
            }
            // The next maintenance session needs its own designation.
            tables(&tx)?;
            tx.execute("DELETE FROM activation_control_session", [])?;
            tx.execute("DELETE FROM activation_control_request", [])?;
            tx.execute("DELETE FROM activation_control_freeze", [])?;
            tx.commit()?;
            Ok(())
        })
    }
}
