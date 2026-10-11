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
                "catalog" => Ok(serde_json::to_string(&client.catalog().await?)?),
                "enroll" => {
                    client
                        .enroll(text("invitation")?, text("socket")?.parse()?)
                        .await?;
                    Ok("null".into())
                }
                "refresh" => {
                    let address = iroh::EndpointAddr::new(text("host")?.parse()?)
                        .with_ip_addr(text("socket")?.parse()?);
                    Ok(serde_json::to_string(&client.refresh(address).await?)?)
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
