//! Durable maintenance freeze and writer release. Local state only; nothing is sent.
use super::*;
use rusqlite::Connection;

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

fn exists(db: &Connection, table: &str) -> anyhow::Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?)",
        [table],
        |r| r.get(0),
    )?)
}

pub(super) fn tables(db: &Connection) -> anyhow::Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS activation_control_freeze (singleton INTEGER PRIMARY KEY CHECK(singleton=1));
        CREATE TABLE IF NOT EXISTS activation_control_releases (certificate BLOB PRIMARY KEY);")?;
    Ok(())
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
            tx.execute("DELETE FROM activation_control_freeze", [])?;
            tx.commit()?;
            Ok(())
        })
    }
}
