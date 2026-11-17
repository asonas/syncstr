//! The startup guard. A host does not serve below its durable profile floor.
use super::*;

impl crate::shared_audio::Store {
    /// Refuse to serve when this build cannot honor the control state of the
    /// store. `supported` lists the profiles this build implements.
    ///
    /// The floor is read from the stored state alone, so a halted journal does
    /// not stop a host from serving what it holds; it refuses writes itself.
    pub fn control_guard(&self, supported: &BTreeSet<String>) -> anyhow::Result<()> {
        self.run(|db, _| {
            let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
            if !freeze::exists(db, "activation_control_state")? {
                ensure!(
                    version == crate::shared_audio::ACTIVATED,
                    "the store is marked for activation control but holds no control storage"
                );
                return Ok(());
            }
            // Without the marker an earlier build could open this store and ignore the floor.
            ensure!(
                version == crate::shared_audio::GUARDED,
                "control storage lacks the startup marker; run `shared-audio-control init`"
            );
            let floor = journal::state(db)?.floor;
            let missing: Vec<_> = floor.difference(supported).cloned().collect();
            ensure!(
                missing.is_empty(),
                "this build does not implement the required profiles: {}",
                missing.join(", ")
            );
            Ok(())
        })
    }
}
