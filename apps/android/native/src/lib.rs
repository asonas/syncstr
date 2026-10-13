#[unsafe(no_mangle)]
pub extern "system" fn Java_as_ason_syncstr_Native_run(
    mut env: jni::JNIEnv,
    _object: jni::objects::JObject,
    root: jni::objects::JString,
    key: jni::objects::JByteArray,
    operation: jni::objects::JString,
    arguments: jni::objects::JString,
) -> jni::sys::jstring {
    let result = (|| -> anyhow::Result<String> {
        let root: String = env.get_string(&root)?.into();
        let key: [u8; 32] = env
            .convert_byte_array(&key)?
            .try_into()
            .map_err(|_| anyhow::anyhow!("invalid device key"))?;
        let operation: String = env.get_string(&operation)?.into();
        let arguments: String = env.get_string(&arguments)?.into();
        anyhow::ensure!(arguments.len() <= 32 * 1024, "request too large");
        let args: serde_json::Value = serde_json::from_str(&arguments)?;
        let client = syncstr_headless::cluster_client::PlaybackClient::open(
            std::path::Path::new(&root),
            key,
        )?;
        let runtime = tokio::runtime::Runtime::new()?;
        runtime.block_on(async {
            let text = |field: &str| {
                args[field]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("missing {field}"))
            };
            match operation.as_str() {
                "id" => Ok(serde_json::to_string(&client.id().to_string())?),
                "hosts" => Ok(serde_json::to_string(&client.hosts().await?)?),
                "catalog" => crate::present_catalog(client.catalog().await?),
                "enroll" => {
                    client
                        .enroll(text("invitation")?, text("socket")?.parse()?)
                        .await?;
                    Ok("null".into())
                }
                "refresh" => {
                    let address = iroh::EndpointAddr::new(text("host")?.parse()?)
                        .with_ip_addr(text("socket")?.parse()?);
                    crate::present_catalog(client.refresh(address).await?)
                }
                "download" => {
                    let sources = args["addresses"]
                        .as_array()
                        .ok_or_else(|| anyhow::anyhow!("missing sources"))?;
                    anyhow::ensure!(sources.len() <= 256, "too many sources");
                    let addresses = sources
                        .iter()
                        .map(|source| {
                            let host = source["host"]
                                .as_str()
                                .ok_or_else(|| anyhow::anyhow!("missing host"))?;
                            let socket = source["socket"]
                                .as_str()
                                .ok_or_else(|| anyhow::anyhow!("missing address"))?;
                            anyhow::Ok(
                                iroh::EndpointAddr::new(host.parse()?)
                                    .with_ip_addr(socket.parse()?),
                            )
                        })
                        .collect::<anyhow::Result<Vec<_>>>()?;
                    Ok(serde_json::to_string(
                        &client.download_from(addresses, text("object")?).await?,
                    )?)
                }
                "local-file" => Ok(serde_json::to_string(
                    &client.local_file(text("object")?).await?,
                )?),
                _ => anyhow::bail!("unsupported operation"),
            }
        })
    })();
    match result {
        Ok(value) => match env.new_string(value) {
            Ok(string) => string.into_raw(),
            Err(_) => std::ptr::null_mut(),
        },
        Err(error) => {
            let _ = env.throw_new("java/lang/IllegalStateException", error.to_string());
            std::ptr::null_mut()
        }
    }
}

fn present_catalog(library: syncstr_headless::cluster_client::Library) -> anyhow::Result<String> {
    let organization = &library.catalog.organization;
    let mut value = serde_json::to_value(&library)?;
    let mut conflicts = library.conflicts.clone();
    let entries = value["entries"]
        .as_array_mut()
        .expect("serialized catalog entries");
    for (entry, projected) in library.catalog.entries.iter().zip(entries) {
        let record = organization
            .tracks
            .iter()
            .find(|track| track.sha256 == entry.sha256);
        let album = match record {
            Some(track) => organization.album_id_for_track(&track.id)?,
            None => entry
                .track
                .album_id
                .as_deref()
                .map(|id| organization.canonical(id).map(str::to_owned))
                .transpose()?,
        };
        let title = album
            .as_ref()
            .and_then(|id| organization.albums.iter().find(|album| &album.id == id))
            .map(|album| album.title.as_str())
            .filter(|title| !title.is_empty())
            .or(entry.track.album.as_deref());
        projected["presentation"] = serde_json::json!({
            "albumId": album,
            "album": title,
            "albumArtist": record.and_then(|track| track.imported.album_artist.as_deref()),
        });
        if record.is_some() && album.is_none() && !conflicts.contains(&entry.sha256) {
            conflicts.push(entry.sha256.clone());
        }
    }
    value["conflicts"] = serde_json::json!(conflicts);
    Ok(serde_json::to_string(&value)?)
}

#[cfg(test)]
mod tests {
    #[test]
    fn android_projection_uses_membership_without_rewriting_imported_metadata() {
        let mut entry: syncstr_headless::model::Entry = serde_json::from_slice(include_bytes!(
            "../../../../headless/fixtures/local-entry.json"
        ))
        .unwrap();
        entry.track.id = "track-a".into();
        let mut organization: syncstr_headless::organization::Organization =
            serde_json::from_slice(include_bytes!(
                "../../../../headless/fixtures/album-organization.json"
            ))
            .unwrap();
        organization.tracks[0].sha256 = entry.sha256.clone();
        let library = syncstr_headless::cluster_client::Library {
            catalog: syncstr_headless::model::Catalog {
                id: "library".into(),
                name: "Fixture".into(),
                entries: vec![entry],
                organization,
            },
            conflicts: vec![],
        };
        let projected: serde_json::Value =
            serde_json::from_str(&crate::present_catalog(library).unwrap()).unwrap();
        assert_eq!(
            projected["entries"][0]["presentation"]["albumId"],
            "album-a"
        );
        assert_eq!(
            projected["entries"][0]["presentation"]["album"],
            "Collection"
        );
        assert_eq!(projected["entries"][0]["track"]["albumId"], "fixture-album");
        assert_eq!(projected["entries"][0]["track"]["discNumber"], 1);
    }
}
