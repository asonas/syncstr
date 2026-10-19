const SERVICE: &str = "_syncstr-cluster._udp.local.";

pub struct Discovery {
    daemon: mdns_sd::ServiceDaemon,
    events: mdns_sd::Receiver<mdns_sd::ServiceEvent>,
}

impl crate::cluster_discovery::Discovery {
    pub fn browse() -> anyhow::Result<Self> {
        let daemon = mdns_sd::ServiceDaemon::new()?;
        match daemon.browse(crate::cluster_discovery::SERVICE) {
            Ok(events) => Ok(Self { daemon, events }),
            Err(error) => {
                let _ = daemon.shutdown();
                Err(error.into())
            }
        }
    }

    pub fn start(endpoint: &iroh::Endpoint) -> anyhow::Result<Self> {
        let daemon = mdns_sd::ServiceDaemon::new()?;
        let result = (|| {
            let address = endpoint.addr();
            let ip = address
                .ip_addrs()
                .find(|address| address.is_ipv4() && !address.ip().is_loopback());
            let id = endpoint.id().to_string();
            if let Some(ip) = ip {
                daemon.register(mdns_sd::ServiceInfo::new(
                    crate::cluster_discovery::SERVICE,
                    &id[..16],
                    &format!("syncstr-{}.local.", &id[..16]),
                    ip.ip(),
                    ip.port(),
                    &[("id", id.as_str()), ("version", "1")][..],
                )?)?;
                eprintln!("Cluster LAN discovery: IPv4 advertisement registered");
            } else {
                eprintln!("Cluster LAN discovery: no IPv4 address available to advertise");
            }
            daemon
                .browse(crate::cluster_discovery::SERVICE)
                .map_err(Into::into)
        })();
        match result {
            Ok(events) => Ok(Self { daemon, events }),
            Err(error) => {
                let _ = daemon.shutdown();
                Err(error)
            }
        }
    }

    pub async fn next(&self) -> anyhow::Result<iroh::EndpointAddr> {
        loop {
            if let mdns_sd::ServiceEvent::ServiceResolved(service) =
                self.events.recv_async().await?
            {
                if service.get_property_val_str("version") != Some("1") {
                    continue;
                }
                let Some(id) = service
                    .get_property_val_str("id")
                    .and_then(|id| id.parse::<iroh::EndpointId>().ok())
                else {
                    continue;
                };
                let ips = service.get_addresses_v4();
                if ips.is_empty() {
                    continue;
                }
                let mut address = iroh::EndpointAddr::new(id);
                for ip in ips {
                    address =
                        address.with_ip_addr(std::net::SocketAddr::from((ip, service.get_port())));
                }
                return Ok(address);
            }
        }
    }
}

impl Drop for crate::cluster_discovery::Discovery {
    fn drop(&mut self) {
        let _ = self.daemon.shutdown();
    }
}
