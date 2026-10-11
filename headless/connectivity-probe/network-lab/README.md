# Disposable Linux connectivity lab

This is an M0 experiment, not a public relay deployment template. It uses the
locked Iroh and Iroh relay 1.3.0 dependencies. All keys and TLS certificates are
generated for the test. The relay accepts only the test's explicitly listed keys;
its backend and TLS proxy listen on loopback. No ports or host directories need
to be published.

From the connectivity-probe directory on macOS with Apple Container running:

```sh
container build --platform linux/arm64 --cpus 4 --memory 4G \
  -t syncstr-network-lab:m0 -f network-lab/Dockerfile .
container run --rm --name syncstr-network-lab --cpus 2 --memory 2G \
  --cap-add CAP_NET_ADMIN --cap-add CAP_SYS_ADMIN --cap-add CAP_NET_RAW \
  --env SYNCSTR_ISOLATED_NETWORK_LAB=1 syncstr-network-lab:m0
```

Network administration capabilities apply only inside this disposable VM. Do not
run `run.sh` or the ignored network-fault tests directly on a host or production
container. The script creates and removes two network namespaces. Each has only
loopback and one end of a veth link, with no IPv4 or IPv6 WAN route.

The experiments cover:

- An established QUIC connection changes from direct to relay after both IPv4
  and IPv6 UDP are dropped, then returns to direct after removing those rules.
  Each observed phase verifies a 64 KiB fixture's fixed SHA-256.
- Separate processes discover each other using DNS-SD and transfer verified
  data between WAN-isolated namespaces. Only the expected peer ID is supplied
  to the discovering process; no peer IP or relay is supplied.
- A separate relay process behind an nginx TLS/WebSocket proxy provides health
  information, rejects unknown keys and untrusted certificates, and transfers
  a verified fixture before and after process termination and restart. Admission
  restrictions must still hold after restart.

The test TLS root is trusted only by test clients. Public ACME issuance, physical
devices behind independent NATs, and mobile background behavior require later
deployment/application verification. A successful health response identifies the
relay process and version; it does not prove transfer availability by itself.
