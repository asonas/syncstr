# LAN discovery investigation

## Current finding

The enrollment and host-restart tests still fail in the investigated macOS
execution environment. A discovery-only reproduction also timed out in three
seconds, before enrollment or replica transfer was involved.

Temporary mDNS monitoring showed advertisement events without daemon errors.
Lower-level send logging then showed `No route to host (os error 65)` for IPv4
multicast on the physical interface. A multicast route existed and the system
application firewall was disabled. Selecting only the endpoint's interface did
not change the failure. Standard Bonjour registration and browsing worked;
Rust could receive the standard advertiser through loopback.

These observations isolate a multicast-send failure in this execution context.
They do not establish a defect in enrollment authentication, and do not prove
which OS policy or network condition rejects the send. Local network privacy is
a candidate: Apple's [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
explains that macOS can attribute a helper's network access to its responsible
application.

## Next check

Check the launching application's Local Network access in System Settings,
then rerun from an authorized terminal:

```sh
cargo test --locked --features p2p --test lan_process -- --test-threads=1 --nocapture
```

Compare that result with the agent execution environment and, separately, the
manual LAN workflow. Do not increase timeouts or bypass identity checks to
compensate for an OS-level send failure. No privacy setting, route, firewall,
installed application, or production service was changed in this investigation.
Temporary loggers, dependency changes, and comparison advertisements were
removed. Physical-device discovery and replication remain unverified.
