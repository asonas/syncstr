#[derive(Clone)]
pub struct Config {
    pub root: std::path::PathBuf,
    pub copy_from: Option<std::path::PathBuf>,
    pub host: Option<super::Host>,
    pub muted: bool,
}
impl Config {
    pub fn arguments() -> anyhow::Result<Self> {
        let mut config = Self {
            root: std::path::PathBuf::from(
                std::env::var_os("LOCALAPPDATA")
                    .ok_or_else(|| anyhow::anyhow!("LOCALAPPDATA is unavailable"))?,
            )
            .join("SyncstrDesktop"),
            copy_from: None,
            host: None,
            muted: false,
        };
        let mut arguments = std::env::args().skip(1);
        while let Some(argument) = arguments.next() {
            match argument.as_str() {
                "--profile" => {
                    config.root = arguments
                        .next()
                        .ok_or_else(|| anyhow::anyhow!("--profile needs a directory"))?
                        .into()
                }
                "--copy-win32-profile" => {
                    config.copy_from = Some(
                        arguments
                            .next()
                            .ok_or_else(|| {
                                anyhow::anyhow!("--copy-win32-profile needs a source directory")
                            })?
                            .into(),
                    )
                }
                "--host" => {
                    let value = arguments
                        .next()
                        .ok_or_else(|| anyhow::anyhow!("--host needs member@address"))?;
                    let (member, socket) = value
                        .split_once('@')
                        .ok_or_else(|| anyhow::anyhow!("--host needs member@address"))?;
                    config.host = Some(super::Host {
                        member: member.into(),
                        socket: socket.parse()?,
                    });
                }
                "--muted" => config.muted = true,
                "--demo" => {}
                _ => anyhow::bail!("Unknown option: {argument}"),
            }
        }
        if !config.root.is_absolute() {
            config.root = std::env::current_dir()?.join(config.root);
        }
        Ok(config)
    }
}
