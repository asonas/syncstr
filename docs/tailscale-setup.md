# Connect your phone to your host over Tailscale

This guide puts a Syncstr host and your iPhone on one tailnet, so that the phone downloads music from the host at a host address such as `https://music.example.ts.net`. It describes the planned setup of [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md). The Tailscale steps work today. The Syncstr steps marked "Planned" do not exist yet. This guide authorizes no change to a running library.

| Step | Today | Planned |
| --- | --- | --- |
| Put the host machine on your tailnet | Works | Same |
| Publish the host with `tailscale serve` | Works with the `serve` command of [headless Syncstr](../headless/README.md) | The macOS app shows the `tailscale serve` command for you to copy and run, because the sandboxed app may be unable to run it ([the publish confirmation](onboarding-and-connection-states.md#the-publish-confirmation), ASO-163) |
| Put the phone on your tailnet | Works | Same |
| Open the host address from the phone | Works in Safari | The macOS app checks the address after you run the command (ASO-163) |
| Open the library in Syncstr | Not possible. The apps find a host only by mDNS at a private LAN address ([`ClusterDiscovery.swift`](../apps/macos/ClusterDiscovery.swift)). ASO-159 tests the path with a throwaway build and the legacy token. | Scan the host's QR code or enter its host address. The app opens the library if the tailnet policy lets the phone reach the host (ASO-164). |

## What you need

- A host machine, either a Mac that runs the macOS app or a NAS that runs the host in a container. It must be on and connected whenever the phone downloads.
- An iPhone with the Syncstr app.
- A tailnet. A free Tailscale Personal account is enough.

When you finish, the phone downloads from the host wherever Tailscale is connected, at home or on cellular, with no Syncstr account and no server in between. Offline saves keep playing when the phone cannot reach the host.

Before publishing the read service, check who can reach the host's HTTPS port under the effective tailnet policy. For example, allow the personal phone and check that a work computer outside the intended set cannot connect. All devices with effective access to that port can read the library.

## Publish a Mac host

Use the Standalone or the Mac App Store variant of Tailscale. Both can publish a port with Serve, but neither runs before a user logs in, so the host is reachable only while someone is logged in to the Mac. The open-source `tailscaled` variant runs before login, and Tailscale recommends it only for experienced administrators.

1. Install Tailscale on the Mac and sign in.
2. Make the `tailscale` command available. In the Standalone variant, open **Settings**, find the CLI integration section, and select **Install Now**. In the Mac App Store variant, add an alias to the command inside the app:

   ```sh
   alias tailscale=/Applications/Tailscale.app/Contents/MacOS/Tailscale
   ```

3. Choose names that you are willing to make public. Let's Encrypt records every certificate in the public Certificate Transparency logs. When Serve gets a certificate, the full name, such as `music.example.ts.net`, becomes public and stays public. In the admin console, open **Machines**, open the Mac's menu, select **Edit machine name**, and enter a name such as `music`. If you want a randomized tailnet DNS name, choose it now. You cannot regenerate a randomized name after a certificate uses it.
4. Turn on HTTPS for the tailnet. On the **DNS** page of the admin console, turn on MagicDNS if it is off. Under **HTTPS Certificates**, select **Enable HTTPS** and accept the notice.
5. Publish the host. The planned host listens on `127.0.0.1:8441` with plain HTTP ([Host API design](host-api-design.md)). `--bg` keeps the setting across restarts.

   ```sh
   tailscale serve --bg 8441
   ```

   Today's `serve` listens on `127.0.0.1:8443` with HTTPS and its own certificate. To publish it, run `tailscale serve --bg https+insecure://127.0.0.1:8443`. `https+insecure` tells Serve to accept that certificate.
6. Run `tailscale serve status` and note the host address that it shows.

Do not use `tailscale funnel`. Funnel publishes a service to the internet.

## Publish a NAS host

The NAS host joins the tailnet through Tailscale installed on the NAS, or through a Tailscale container in the same network namespace as the host. Q7 of the [device spike](validation/tailscale-device-spike.md) compares the two.

| Option | What you add | What you maintain | Host address |
| --- | --- | --- | --- |
| A Tailscale container next to the host | One `tailscale/tailscale` container in the host's Compose file | One more image, updated with the host. The Serve setting is a file. | `music.<tailnet>.ts.net`, for the host only |
| Tailscale on the NAS | The Tailscale package for your NAS system | A package whose install and update route differs by system. Synology's Package Center build is no longer supported. | The NAS's own name. The whole NAS joins the tailnet. |

Use the Tailscale container if you want the least to maintain. It works the same on every NAS that runs containers, starts and stops with the host, and puts only the host on your tailnet. The device spike (ASO-159) tests this choice.

1. Choose the host's machine name, such as `music`, for the `hostname` setting in step 4. The warning about public certificate logs in step 3 of the Mac section applies here. Then turn on HTTPS as in step 4 of the Mac section.
2. In the admin console, open **Keys**, select **Generate auth key**, keep it one-off, and copy the key. This key enrolls the NAS container in Tailscale. The listener never enters it in Syncstr.
3. Next to the host's `compose.yaml`, create `tailscale/serve.json`. The container replaces `${TS_CERT_DOMAIN}` with the machine's full name.

   ```json
   {
     "TCP": { "443": { "HTTPS": true } },
     "Web": {
       "${TS_CERT_DOMAIN}:443": {
         "Handlers": { "/": { "Proxy": "http://127.0.0.1:8441" } }
       }
     }
   }
   ```

   Today's container listens on port 8443 with HTTPS ([`Dockerfile`](../headless/Dockerfile)). For it, write `https+insecure://127.0.0.1:8443` as the proxy.

4. Add a `tailscale` service, attach the host to its network, and delete the host's `ports` entry. After this change, the LAN does not reach the host directly.

   ```yaml
   services:
     tailscale:
       image: tailscale/tailscale:latest
       hostname: music
       environment:
         - TS_AUTHKEY=tskey-auth-EXAMPLE
         - TS_AUTH_ONCE=true
         - TS_STATE_DIR=/var/lib/tailscale
         - TS_SERVE_CONFIG=/config/serve.json
       volumes:
         - ./tailscale/state:/var/lib/tailscale
         - ./tailscale/serve.json:/config/serve.json:ro
       restart: unless-stopped
     syncstr:
       # Keep the existing build, user, and volume settings.
       network_mode: service:tailscale
       depends_on: [tailscale]
   ```

   `TS_STATE_DIR` on a volume keeps the machine signed in across restarts. `TS_AUTH_ONCE=true` stops the container from signing in again at every start, which fails after the auth key expires.
5. Start both containers with `docker compose up -d`.
6. In the admin console, open **Machines**, open the menu of `music`, and select **Disable Key Expiry**. Otherwise the machine leaves the tailnet after 180 days until you sign it in again.

For Tailscale on the NAS, follow Tailscale's guide for your system, then run the Mac section's `tailscale serve` command on the NAS. [`headless/compose.yaml`](../headless/compose.yaml) already keeps the host's port on the NAS's loopback address. Tailscale's NAS guides do not mention Serve, so this path is untested.

## Connect the phone

1. Install Tailscale from the App Store.
2. Open it, tap **Get Started**, accept the prompt to add a VPN configuration, and log in with the account that owns the host machine.
3. To check the path with today's `serve`, open `https://music.example.ts.net/v4/catalog` in Safari. It answers `unauthorized` to a request without a token ([`api.rs`](../headless/src/api.rs)). That answer shows that Tailscale, the certificate, Serve, and the host all work.
4. For the planned read API, open the host’s tailnet HTTPS address in Syncstr. An allowed phone can browse and download immediately. The legacy fixture token in step 3 belongs only to the ASO-159 experiment.

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

The planned read service binds to loopback, including in the NAS container network namespace, and Serve provides its only remote entry point. A home LAN address is used only as a comparison in the device spike.

See [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve) and [grants syntax](https://tailscale.com/docs/reference/syntax/grants).

## Troubleshooting

| Symptom | Likely cause | What to check |
| --- | --- | --- |
| `tailscale serve` asks you to enable HTTPS | HTTPS is off for the tailnet | **HTTPS Certificates** on the **DNS** page |
| Safari on the phone cannot find the host address | Tailscale is off on the phone, or signed in to another tailnet | The Tailscale app shows a connection with the right account, or an accepted share |
| The address worked before and now fails everywhere | The host machine is off or asleep, nobody is logged in to the Mac, or the machine's key expired | The host's state on **Machines**, and the Mac's login |
| The legacy fixture probe does not return `unauthorized` | Serve runs, but the host does not listen on the port that Serve forwards to | `tailscale serve status` and the host's listen address |
| Safari warns about the certificate | You opened the `100.x` address or the short name | Use the full name, such as `https://music.example.ts.net` |
| Tailscale on the phone keeps disconnecting | Another VPN took over | Connect Tailscale by hand. Only one VPN runs at a time. |
| A person with a share cannot reach the host | They used the short name, or did not accept the share | The full name, and the share on **Machines** |
| Downloads are slow away from home | Traffic goes through a Tailscale DERP server instead of a direct path | During a download, the phone's line in `tailscale status` on the host shows `direct` and an address for a direct path. Otherwise it names a DERP region. |

## Open questions

- Which NAS option becomes the one documented command? Q7 of the [device spike](validation/tailscale-device-spike.md) informs it. ASO-163.
- Can the macOS app configure Serve with one confirmation, so that you copy no command? A prototype settles it, as open question 1 of [Onboarding and connection states](onboarding-and-connection-states.md#open-questions) describes. ASO-163.

ASO-159 uses the direct-IP path as a measurement comparison. What the macOS app shows when Tailscale is missing or HTTPS is off is in [Onboarding and connection states](onboarding-and-connection-states.md#on-the-mac-as-a-host).

## Sources

Read on 2026-11-17.

- Tailscale: "Tailscale Serve", "tailscale serve command", "Enabling HTTPS", "Three ways to run Tailscale on macOS", "Tailscale CLI", "Machine names", "Tailnet names and types", "Auth keys", "Key expiry", "Subnet routers", "Install Tailscale on iOS", "Using VPN On Demand for iOS and macOS", "Share your machines with other users", "Inviting users vs sharing a device", "Access Synology NAS from anywhere", and "Access NAS, media servers, or file shares remotely", in the Tailscale documentation.
- Tailscale: "Contain your excitement: A deep dive into using Tailscale with Docker", its example repository `tailscale-dev/docker-guide-code-examples`, and the `containerboot` package documentation.
- Tailscale: `tailscale serve --help` of Tailscale 1.104.5, and `expandProxyArg` in `ipn/ipnlocal/serve.go` of `tailscale/tailscale`, for the `https+insecure` target.
- Apple: "Trust manually installed certificate profiles in iOS, iPadOS, and visionOS" (Apple Support).
