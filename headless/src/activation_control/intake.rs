//! The input history a host acknowledges, and the pin that keeps it unchanged.
use super::*;
use rusqlite::Connection;

/// Digest of the identifiers of the signed music and playlist records this
/// host holds. Membership is covered by the membership revision instead.
pub(super) fn input_history(db: &Connection) -> anyhow::Result<Digest> {
    let mut hash = Sha256::new();
    hash.update(b"syncstr-activation-input-history-v1\n");
    for table in ["shared_records", "shared_playlists"] {
        let count: i64 =
            db.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))?;
        hash.update(count.to_be_bytes());
        let mut statement = db.prepare(&format!("SELECT id FROM {table} ORDER BY id"))?;
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            hash.update((id.len() as u64).to_be_bytes());
            hash.update(id.as_bytes());
        }
    }
    Ok(hash.finalize().into())
}

/// Call in the transaction that stores a replicated record this host did not
/// hold. A host that acknowledged its input history keeps it until the
/// proposal is installed or aborted.
pub(crate) fn ensure_intake(db: &Connection) -> anyhow::Result<()> {
    if !freeze::exists(db, "activation_control_state")? {
        return Ok(());
    }
    let inspection = journal::inspect(db).map_err(|_| Refusal::Review)?;
    ensure!(
        inspection.pending_certificates.is_empty()
            && !inspection
                .prepare_locks
                .iter()
                .any(|id| inspection.pending_preparations.contains(id)),
        "input history is pinned by a pending activation"
    );
    Ok(())
}

impl crate::shared_audio::Store {
    /// The digest this host would acknowledge in a prepared acknowledgment.
    pub fn control_input_history(&self) -> anyhow::Result<Digest> {
        self.run(|db, _| input_history(db))
    }
}
