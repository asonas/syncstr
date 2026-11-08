#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum SaveState {
    Waiting,
    Running,
    Partial,
    Complete,
    Cancelled,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum SaveItemState {
    Pending,
    Saved,
    Failed,
    Removed,
}
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SaveItem {
    pub pin: crate::catalog_client::ExactTrack,
    pub state: crate::catalog_client::SaveItemState,
    pub error: Option<crate::catalog_client::Error>,
}
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SaveJob {
    pub id: String,
    pub library: String,
    pub album: Option<String>,
    pub items: Vec<crate::catalog_client::SaveItem>,
    pub state: crate::catalog_client::SaveState,
}

pub(super) fn restore(
    connection: &rusqlite::Connection,
) -> Result<(), crate::catalog_client::Error> {
    connection.execute_batch("CREATE TABLE IF NOT EXISTS client_save_jobs (id TEXT PRIMARY KEY, payload BLOB NOT NULL)").map_err(|_| crate::catalog_client::Error::Storage)?;
    for mut job in jobs(connection)? {
        if job.state == crate::catalog_client::SaveState::Running {
            job.state = crate::catalog_client::SaveState::Waiting;
            write(connection, &job)?;
        }
    }
    Ok(())
}

fn jobs(
    connection: &rusqlite::Connection,
) -> Result<Vec<crate::catalog_client::SaveJob>, crate::catalog_client::Error> {
    let mut statement = connection
        .prepare("SELECT id, payload FROM client_save_jobs ORDER BY rowid")
        .map_err(|_| crate::catalog_client::Error::Storage)?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?))
        })
        .map_err(|_| crate::catalog_client::Error::Storage)?;
    rows.map(|row| {
        let (id, bytes) = row.map_err(|_| crate::catalog_client::Error::Storage)?;
        let job: crate::catalog_client::SaveJob =
            serde_json::from_slice(&bytes).map_err(|_| crate::catalog_client::Error::Storage)?;
        if job.id != id
            || job.items.is_empty()
            || job.items.len() > 100_000
            || job
                .items
                .iter()
                .any(|item| !crate::catalog_client::projection::hash(&item.pin.sha256))
        {
            return Err(crate::catalog_client::Error::Storage);
        }
        Ok(job)
    })
    .collect()
}

fn write(
    connection: &rusqlite::Connection,
    job: &crate::catalog_client::SaveJob,
) -> Result<(), crate::catalog_client::Error> {
    let bytes = serde_json::to_vec(job).map_err(|_| crate::catalog_client::Error::Storage)?;
    connection
        .execute(
            "INSERT OR REPLACE INTO client_save_jobs VALUES (?, ?)",
            rusqlite::params![job.id, bytes],
        )
        .map_err(|_| crate::catalog_client::Error::Storage)?;
    Ok(())
}

impl crate::catalog_client::Client {
    pub fn save_jobs(
        &self,
    ) -> Result<Vec<crate::catalog_client::SaveJob>, crate::catalog_client::Error> {
        self.ensure_open()?;
        jobs(
            self.connection
                .as_ref()
                .ok_or(crate::catalog_client::Error::Closed)?,
        )
    }

    pub fn saved_tracks(
        &self,
    ) -> Result<Vec<crate::catalog_client::ExactTrack>, crate::catalog_client::Error> {
        self.ensure_open()?;
        let mut statement = self
            .connection
            .as_ref()
            .ok_or(crate::catalog_client::Error::Closed)?
            .prepare("SELECT track, hash FROM client_saves ORDER BY track, hash")
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        statement
            .query_map([], |row| {
                Ok(crate::catalog_client::ExactTrack {
                    track_id: row.get(0)?,
                    sha256: row.get(1)?,
                })
            })
            .map_err(|_| crate::catalog_client::Error::Storage)?
            .map(|row| row.map_err(|_| crate::catalog_client::Error::Storage))
            .collect()
    }

    pub fn save_tracks(
        &mut self,
        pins: &[crate::catalog_client::ExactTrack],
    ) -> Result<crate::catalog_client::SaveJob, crate::catalog_client::Error> {
        self.accept_save(None, pins)
    }

    pub fn save_album(
        &mut self,
        album: &str,
    ) -> Result<crate::catalog_client::SaveJob, crate::catalog_client::Error> {
        let view = self.catalog()?;
        let album = view
            .album_aliases
            .get(album)
            .map_or(album, String::as_str)
            .to_owned();
        let pins: Vec<_> = view
            .tracks
            .values()
            .filter(|track| track.album_id == album)
            .map(|track| {
                track
                    .preferred
                    .clone()
                    .ok_or(crate::catalog_client::Error::InvalidPin)
            })
            .collect::<Result<_, _>>()?;
        self.accept_save(Some(album), &pins)
    }

    fn accept_save(
        &mut self,
        album: Option<String>,
        pins: &[crate::catalog_client::ExactTrack],
    ) -> Result<crate::catalog_client::SaveJob, crate::catalog_client::Error> {
        self.ensure_open()?;
        if pins.is_empty() || pins.len() > 100_000 {
            return Err(crate::catalog_client::Error::InvalidPin);
        }
        let view = self.catalog()?;
        let mut items = Vec::new();
        for pin in pins {
            let pin = self.audio_pin(&pin.track_id, Some(&pin.sha256))?;
            if items
                .iter()
                .any(|item: &crate::catalog_client::SaveItem| item.pin == pin)
            {
                continue;
            }
            items.push(crate::catalog_client::SaveItem {
                pin,
                state: crate::catalog_client::SaveItemState::Pending,
                error: None,
            });
        }
        let mut job = crate::catalog_client::SaveJob {
            id: uuid::Uuid::new_v4().to_string(),
            library: view
                .library
                .clone()
                .ok_or(crate::catalog_client::Error::InvalidCatalog)?,
            album,
            items,
            state: crate::catalog_client::SaveState::Waiting,
        };
        let transaction = self
            .connection
            .as_mut()
            .ok_or(crate::catalog_client::Error::Closed)?
            .transaction()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        let mut assets = Vec::new();
        for item in &mut job.items {
            let Some(bytes) = view.audio_bytes(&item.pin) else {
                continue;
            };
            match self.audio.lease(
                item.pin.clone(),
                bytes,
                self.lock
                    .as_ref()
                    .ok_or(crate::catalog_client::Error::Closed)?
                    .clone(),
            ) {
                Ok(asset) => {
                    transaction
                        .execute(
                            "INSERT OR IGNORE INTO client_saves VALUES (?, ?)",
                            rusqlite::params![item.pin.track_id, item.pin.sha256],
                        )
                        .map_err(|_| crate::catalog_client::Error::Storage)?;
                    item.state = crate::catalog_client::SaveItemState::Saved;
                    assets.push(asset);
                }
                Err(
                    crate::catalog_client::Error::UnavailableSource
                    | crate::catalog_client::Error::Integrity,
                ) => {}
                Err(error) => return Err(error),
            }
        }
        if job
            .items
            .iter()
            .all(|item| item.state == crate::catalog_client::SaveItemState::Saved)
        {
            job.state = crate::catalog_client::SaveState::Complete;
        }
        write(&transaction, &job)?;
        transaction
            .commit()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        for asset in &assets {
            self.audio.protect(&asset.pin().sha256)?;
        }
        Ok(job)
    }

    pub async fn run_save(
        &mut self,
        id: &str,
        hosts: &[crate::catalog_client::Host],
        secret: Option<[u8; 32]>,
        operation: &crate::catalog_client::Operation,
    ) -> Result<crate::catalog_client::SaveJob, crate::catalog_client::Error> {
        let mut job = self
            .save_jobs()?
            .into_iter()
            .find(|job| job.id == id)
            .ok_or(crate::catalog_client::Error::InvalidPin)?;
        if job.state == crate::catalog_client::SaveState::Cancelled {
            return Err(crate::catalog_client::Error::Cancelled);
        }
        job.state = crate::catalog_client::SaveState::Running;
        write(
            self.connection
                .as_ref()
                .ok_or(crate::catalog_client::Error::Closed)?,
            &job,
        )?;
        for index in 0..job.items.len() {
            if job.items[index].state == crate::catalog_client::SaveItemState::Removed {
                continue;
            }
            let pin = job.items[index].pin.clone();
            match self.acquire(&pin, hosts, secret, operation, true).await {
                Ok(asset) => {
                    if operation
                        .cancelled
                        .load(std::sync::atomic::Ordering::Acquire)
                    {
                        job.state = crate::catalog_client::SaveState::Waiting;
                        write(
                            self.connection
                                .as_ref()
                                .ok_or(crate::catalog_client::Error::Closed)?,
                            &job,
                        )?;
                        return Err(crate::catalog_client::Error::Cancelled);
                    }
                    job.items[index].state = crate::catalog_client::SaveItemState::Saved;
                    job.items[index].error = None;
                    let transaction = self
                        .connection
                        .as_mut()
                        .ok_or(crate::catalog_client::Error::Closed)?
                        .transaction()
                        .map_err(|_| crate::catalog_client::Error::Storage)?;
                    transaction
                        .execute(
                            "INSERT OR IGNORE INTO client_saves VALUES (?, ?)",
                            rusqlite::params![pin.track_id, pin.sha256],
                        )
                        .map_err(|_| crate::catalog_client::Error::Storage)?;
                    write(&transaction, &job)?;
                    transaction
                        .commit()
                        .map_err(|_| crate::catalog_client::Error::Storage)?;
                    self.audio.protect(&asset.pin().sha256)?;
                }
                Err(
                    error @ (crate::catalog_client::Error::Cancelled
                    | crate::catalog_client::Error::PolicyRestricted
                    | crate::catalog_client::Error::AuthenticationRequired),
                ) => {
                    job.state = crate::catalog_client::SaveState::Waiting;
                    job.items[index].error = Some(error);
                    write(
                        self.connection
                            .as_ref()
                            .ok_or(crate::catalog_client::Error::Closed)?,
                        &job,
                    )?;
                    if error == crate::catalog_client::Error::Cancelled {
                        return Err(error);
                    }
                    return Ok(job);
                }
                Err(error) => {
                    job.items[index].state = crate::catalog_client::SaveItemState::Failed;
                    job.items[index].error = Some(error);
                }
            }
            write(
                self.connection
                    .as_ref()
                    .ok_or(crate::catalog_client::Error::Closed)?,
                &job,
            )?;
        }
        job.state = if job.items.iter().all(|item| {
            matches!(
                item.state,
                crate::catalog_client::SaveItemState::Saved
                    | crate::catalog_client::SaveItemState::Removed
            )
        }) {
            crate::catalog_client::SaveState::Complete
        } else {
            crate::catalog_client::SaveState::Partial
        };
        write(
            self.connection
                .as_ref()
                .ok_or(crate::catalog_client::Error::Closed)?,
            &job,
        )?;
        if operation
            .cancelled
            .load(std::sync::atomic::Ordering::Acquire)
        {
            job.state = crate::catalog_client::SaveState::Waiting;
            write(
                self.connection
                    .as_ref()
                    .ok_or(crate::catalog_client::Error::Closed)?,
                &job,
            )?;
            return Err(crate::catalog_client::Error::Cancelled);
        }
        Ok(job)
    }

    pub fn cancel_save(&mut self, id: &str) -> Result<(), crate::catalog_client::Error> {
        self.set_save_state(id, crate::catalog_client::SaveState::Cancelled)
    }
    pub fn retry_save(&mut self, id: &str) -> Result<(), crate::catalog_client::Error> {
        self.set_save_state(id, crate::catalog_client::SaveState::Waiting)
    }
    fn set_save_state(
        &mut self,
        id: &str,
        state: crate::catalog_client::SaveState,
    ) -> Result<(), crate::catalog_client::Error> {
        let mut job = self
            .save_jobs()?
            .into_iter()
            .find(|job| job.id == id)
            .ok_or(crate::catalog_client::Error::InvalidPin)?;
        job.state = state;
        write(
            self.connection
                .as_ref()
                .ok_or(crate::catalog_client::Error::Closed)?,
            &job,
        )
    }

    pub fn remove_save(
        &mut self,
        pin: &crate::catalog_client::ExactTrack,
    ) -> Result<(), crate::catalog_client::Error> {
        let pin = self.audio_pin(&pin.track_id, Some(&pin.sha256))?;
        let mut jobs = self.save_jobs()?;
        let transaction = self
            .connection
            .as_mut()
            .ok_or(crate::catalog_client::Error::Closed)?
            .transaction()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        transaction
            .execute(
                "DELETE FROM client_saves WHERE track=? AND hash=?",
                rusqlite::params![pin.track_id, pin.sha256],
            )
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        transaction.execute("UPDATE client_audio SET remove_when_unused=1 WHERE hash=? AND NOT EXISTS(SELECT 1 FROM client_saves WHERE hash=?)", rusqlite::params![pin.sha256, pin.sha256]).map_err(|_| crate::catalog_client::Error::Storage)?;
        for job in &mut jobs {
            for item in &mut job.items {
                if item.pin == pin {
                    item.state = crate::catalog_client::SaveItemState::Removed;
                    item.error = None;
                }
            }
            write(&transaction, job)?;
        }
        transaction
            .commit()
            .map_err(|_| crate::catalog_client::Error::Storage)?;
        self.audio.remove_save(
            self.connection
                .as_ref()
                .ok_or(crate::catalog_client::Error::Closed)?,
            &pin,
        )
    }
}
