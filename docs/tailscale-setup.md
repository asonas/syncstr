# Connect your phone to your host over Tailscale

This guide puts a Syncstr host and your iPhone on one tailnet, so that the phone downloads music from the host at a host address such as `https://syncstr.example.ts.net`. The host runs [headless Syncstr](../headless/README.md). The Mac and iPhone apps open the same HTTPS address and read the library over `/api/v1`. The [TestFlight checklist](validation/tailscale-testflight-qa.md) covers physical-device verification.

## What you need

- A host machine, running headless Syncstr, such as a Mac or a NAS. It must be on and connected whenever the phone downloads.
- An iPhone with the Syncstr app.
- A tailnet. A free Tailscale Personal account is enough.

When you finish, the phone downloads from the host wherever Tailscale is connected, at home or on cellular, with no Syncstr account and no relay that Syncstr runs. Offline saves keep playing when the phone cannot reach the host.

Before publishing the read service, check who can reach the host's HTTPS port under the effective tailnet policy. For example, allow the personal phone and check that a work computer outside the intended set cannot connect. All devices with effective access to that port can read the library.

## Publish a Mac host

Use the Standalone or the Mac App Store variant of Tailscale. Both can publish a port with Serve, but neither runs before a user logs in, so the host is reachable only while someone is logged in to the Mac. The open-source `tailscaled` variant runs before login, and Tailscale recommends it only for experienced administrators.

1. Install Tailscale on the Mac and sign in.
2. Make the `tailscale` command available. In the Standalone variant, open **Settings**, find the CLI integration section, and select **Install Now**. In the Mac App Store variant, add an alias to the command inside the app:

   ```sh
   alias tailscale=/Applications/Tailscale.app/Contents/MacOS/Tailscale
   ```

3. Choose names that you are willing to make public. Let's Encrypt records every certificate in the public Certificate Transparency logs. When Serve gets a certificate, the full name, such as `syncstr.example.ts.net`, becomes public and stays public. In the admin console, open **Machines**, open the Mac's menu, select **Edit machine name**, and enter a name such as `syncstr`. If you want a randomized tailnet DNS name, choose it now. You cannot regenerate a randomized name after a certificate uses it.
4. Turn on HTTPS for the tailnet. On the **DNS** page of the admin console, turn on MagicDNS if it is off. Under **HTTPS Certificates**, select **Enable HTTPS** and accept the notice.
5. Publish the host. The headless read API can listen on `127.0.0.1:8441` with plain HTTP ([Host API design](host-api-design.md)). `--bg` keeps the setting across restarts.

   ```sh
   tailscale serve --bg 8441
   ```

   Publish only the read API. If the Mac runs `tailscaled` in userspace mode, use the listener addresses and explicit Serve target in the NAS section.
6. Run `tailscale serve status` and note the host address that it shows.

Do not use `tailscale funnel`. Funnel publishes a service to the internet.

## Publish a NAS host

For an existing library, follow the [migration plan](private-network-migration-plan.md#steps-that-need-the-owners-go-ahead).

| Option | What you add | What you maintain | Host address |
| --- | --- | --- | --- |
| A Tailscale container next to the host | One `tailscale/tailscale` container in the host's Compose file | One more image, updated with the host. The Serve setting is a file. | `syncstr.<tailnet>.ts.net`, for the host only |
| Tailscale on the NAS | The Tailscale package for your NAS system | A package whose install and update route differs by system. Synology's Package Center build is no longer supported. | The NAS's own name. The whole NAS joins the tailnet. |

The deployed NAS uses a userspace sidecar with persistent state. A push to the deployment repository's `main` triggers a GitHub webhook. Serve forwards every path to the read API. P2P and rendezvous are off. No Syncstr port is published on the LAN.

With `TS_USERSPACE=true`, Tailscale forwards tailnet TCP connections on ports outside Serve to the same port on `127.0.0.1` (`acceptTCP` in `wgengine/netstack/netstack.go`). Bind both node listeners to `127.0.0.2` in the shared namespace. This assumes no advertised subnet routes and no Tailscale SSH. Limit the node's tailnet policy to TCP 443 as well. Recheck this forwarding behavior and both direct ports whenever the Tailscale image changes.

The example below uses a fresh project directory named `trial` beside the `headless` source directory. Relative mounts start at `trial/compose.yaml`.

1. Choose an unused machine name for the `hostname` setting in step 4. `syncstr` is a placeholder for the machine name. The warning about public certificate logs in step 3 of the Mac section applies here. Then turn on HTTPS as in step 4 of the Mac section.
2. In the admin console, open **Keys**, select **Generate auth key**, keep it one-off, and set `TS_AUTHKEY` in the project shell to that key. This key enrolls the NAS container in Tailscale. The listener never enters it in Syncstr.
3. Check the paths for `tailscale/state` and `tailscale/config` under `trial`. Stop if either directory exists or any path component is a symlink. Create both directories empty. Check that `tailscale/config/serve.json` is absent, including as a dangling symlink. Create it as a new file without overwriting any entry. Step 4 mounts the `config` directory, not the file, because Tailscale detects changes to the file only through a directory mount ([Docker configuration parameters](https://tailscale.com/docs/features/containers/docker/docker-params)). The container replaces `${TS_CERT_DOMAIN}` with the machine's full name.

   ```json
   {
     "TCP": { "443": { "HTTPS": true } },
     "Web": {
       "${TS_CERT_DOMAIN}:443": {
         "Handlers": { "/": { "Proxy": "http://127.0.0.2:8441" } }
       }
     }
   }
   ```

4. Set `--api-address` to the sidecar's HTTPS origin. Save this as `trial/compose.yaml`. The sidecar forwards to the read API's plain HTTP listener in their shared namespace. The Compose file publishes no LAN port.

   ```yaml
   services:
     tailscale:
       image: tailscale/tailscale:latest
       hostname: syncstr
       environment:
         - TS_AUTHKEY
         - TS_USERSPACE=true
         - TS_AUTH_ONCE=true
         - TS_STATE_DIR=/var/lib/tailscale
         - TS_SERVE_CONFIG=/config/serve.json
       volumes:
         - ./tailscale/state:/var/lib/tailscale
         - ./tailscale/config:/config:ro
       restart: unless-stopped
     syncstr:
       build:
         context: ../headless
         args:
           SYNCSTR_FEATURES: p2p
       command: ["serve", "--data", "/data", "--identity", "/identity",
                 "--listen", "127.0.0.2:8443", "--api-listen", "127.0.0.2:8441",
                 "--api-address", "https://syncstr.example.ts.net"]
       user: "${SYNCSTR_UID:-1000}:${SYNCSTR_GID:-1000}"
       restart: unless-stopped
       read_only: true
       cap_drop: [ALL]
       security_opt: [no-new-privileges:true]
       volumes:
         - ./data:/data
         - ./identity:/identity:ro
       network_mode: service:tailscale
       depends_on: [tailscale]
   ```

   The build includes `p2p` to read the existing store's signed playlists. The command omits peer and rendezvous options, so neither service starts.

   `TS_STATE_DIR` on a volume keeps the machine signed in across restarts. `TS_AUTH_ONCE=true` stops the container from signing in again at every start, which fails after the auth key expires.

5. From `trial`, prepare fresh `data` and `identity` directories owned by the configured UID and GID. Check that both mounts resolve inside the fixture. Build the fixture and start its sidecar before running the [headless initialization command](../headless/README.md#docker-on-a-nas). Give `init` a writable identity mount for this command only. Replace the example certificate name with the fixture name from step 1 and its tailnet DNS suffix.

   ```sh
   docker compose build syncstr
   docker compose up -d tailscale
   docker compose run --rm --no-deps --volume "$PWD/identity:/identity:rw" \
     syncstr init --identity /identity --host syncstr.example.ts.net
   docker compose up -d syncstr
   ```

   At startup, `serve` reads the legacy listener's token and TLS identity from the read-only mount.

6. In the admin console, open **Machines**. Open the menu for the machine name from step 1 and select **Disable Key Expiry**. Otherwise the machine leaves the tailnet after 180 days until you sign it in again.

For Tailscale on the NAS, follow Tailscale's guide for your system, then run the Mac section's `tailscale serve` command on the NAS. A container listening on `127.0.0.1` inside its own network namespace needs a shared namespace with Serve. A port mapping such as the one in [`headless/compose.yaml`](../headless/compose.yaml) does not reach it. Run the host container with `network_mode: host`, so that its loopback is the NAS's loopback where Serve forwards. Every process on the NAS can then read the library through that port. The image's default command binds the legacy listener to `0.0.0.0:8443`, so with host networking it would also answer on the NAS's LAN address. Configure both listeners explicitly on unused loopback ports before trying this. If the NAS package runs `tailscaled` in userspace mode, the forwarding described above applies to the whole NAS, so use `127.0.0.2` here as well and publish `http://127.0.0.2:8441` as the Serve target instead of the Mac section's `8441`, which forwards to `127.0.0.1`. Some versions of the `tailscale` command may refuse that target on the command line; a Serve configuration file like the sidecar's in step 3 sets it directly. Tailscale's NAS guides do not mention Serve, so this path is untested.

## Connect the phone

1. Install Tailscale from the App Store.
2. Open it, tap **Get Started**, accept the prompt to add a VPN configuration, and log in with the account that owns the host machine.
3. Open `https://syncstr.example.ts.net/api/v1/library` in Safari. An allowed phone should see library information with the host address.
4. Once ASO-165 and ASO-164 reach internal TestFlight, open the same HTTPS origin in Syncstr. Follow the [iPhone checklist](validation/tailscale-testflight-qa.md).

Tailscale must be connected whenever Syncstr downloads. To connect it automatically, tap your profile picture in the Tailscale app, select **VPN On Demand**, and set Wi-Fi and cellular to **Always**.

iOS runs one VPN at a time. If you connect another VPN, Tailscale disconnects. iOS then turns off VPN On Demand for Tailscale until you connect Tailscale again by hand.

## Share the host with another person

To let someone in your household download from your host, share the host machine or invite them to your tailnet.

| | Share the host machine | Invite them to your tailnet |
| --- | --- | --- |
| What they reach | Only the host, by its full name | Every machine in your tailnet, until you limit it with access controls |
| Their account | Their own tailnet. They must be its Owner, Admin, or IT admin to accept the share. | A user in your tailnet. The Personal plan allows up to 6 users. |
| Your user count | Unchanged | One more |
| To undo | In the host's **Share** dialog, select **Revoke invite** | Remove the user |

Share the host machine unless the person needs more of your tailnet. They use the same host address. In the admin console, open **Machines**, open the host's menu, and select **Share**.

Use the tailnet policy to allow the intended device to reach the library host on TCP port 443. Review existing grants and ACLs together: a broader rule may already allow other devices. To withdraw access, remove the effective permission or the device from Tailscale. Offline saves remain on the phone.

The NAS publishes the read API only through Serve.

See [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve) and [grants syntax](https://tailscale.com/docs/reference/syntax/grants).

## Troubleshooting

| Symptom | Likely cause | What to check |
| --- | --- | --- |
| `tailscale serve` asks you to enable HTTPS | HTTPS is off for the tailnet | **HTTPS Certificates** on the **DNS** page |
| Safari on the phone cannot find the host address | Tailscale is off on the phone, or signed in to another tailnet | The Tailscale app shows a connection with the right account, or an accepted share |
| The address worked before and now fails everywhere | The host machine is off or asleep, nobody is logged in to the Mac, or the machine's key expired | The host's state on **Machines**, and the Mac's login |
| Serve returns 502 after deployment | The node opens its store before listening. This took a few tens of seconds on the NAS. | Retry the library request. If it still fails, check the Serve target and both listener addresses. |
| Safari warns about the certificate | You opened the `100.x` address or the short name | Use the full name, such as `https://syncstr.example.ts.net` |
| Tailscale on the phone keeps disconnecting | Another VPN took over | Connect Tailscale by hand. Only one VPN runs at a time. |
| A person with a share cannot reach the host | They used the short name, or did not accept the share | The full name, and the share on **Machines** |
| Downloads are slow away from home | Traffic goes through a Tailscale DERP server instead of a direct path | During a download, the phone's line in `tailscale status` on the host shows `direct` and an address for a direct path. Otherwise it names a DERP region. |

## Open questions

- Does the NAS sidecar rejoin after a reboot without a new login? The owner checks this during an approved restart (ASO-159).

For connection failures on a listening device, see [Onboarding and connection states](onboarding-and-connection-states.md#when-connecting-fails).

## Sources

Read on 2026-11-17.

- Tailscale: "Tailscale Serve", "tailscale serve command", "Enabling HTTPS", "Three ways to run Tailscale on macOS", "Tailscale CLI", "Machine names", "Tailnet names and types", "Auth keys", "Key expiry", "Subnet routers", "Install Tailscale on iOS", "Using VPN On Demand for iOS and macOS", "Share your machines with other users", "Inviting users vs sharing a device", "Access Synology NAS from anywhere", and "Access NAS, media servers, or file shares remotely", in the Tailscale documentation.
- Tailscale: "Contain your excitement: A deep dive into using Tailscale with Docker", its example repository `tailscale-dev/docker-guide-code-examples`, and the `containerboot` package documentation.
- Tailscale: `tailscale serve --help` of Tailscale 1.104.5, and `expandProxyArg` in `ipn/ipnlocal/serve.go` of `tailscale/tailscale`, for Serve proxy targets.
- Apple: "Trust manually installed certificate profiles in iOS, iPadOS, and visionOS" (Apple Support).
