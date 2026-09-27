# Troubleshooting

Symptom → cause → fix. Organised by where the problem is.

The app's **Settings ▸ Diagnostics** screen answers most of these directly, and
**Settings ▸ Logs** has the detail. Both redact credentials before storing
anything.

---

## The build

| Symptom | Cause | Fix |
|---|---|---|
| `xcodegen: command not found` | Homebrew install failed and the fallback did not reach `GITHUB_PATH` | Check `xcodegen.txt` in the `ProxyTunnel-iOS-build-logs` artifact |
| `no such module 'ProxyTunnelCore'` | The package path in `project.yml` no longer matches the directory | It must be `Packages/ProxyTunnelCore` |
| `Signing for "ProxyTunnel" requires a development team` | A signing setting leaked into `project.yml` | The build must pass `CODE_SIGNING_ALLOWED=NO`; do not add a `DEVELOPMENT_TEAM` to the project |
| `Cannot find a simulator named …` | The runner image changed its device list | The workflow picks a device dynamically — remove any hardcoded name |
| Unresolved package `ProxyTunnelCore` | A stale generated project | Delete `ProxyTunnel.xcodeproj` and re-run `xcodegen generate` |
| `The request was denied because it was not run from a workflow file on the default branch` | `gh workflow run` before the workflow was pushed | Push first |
| Build fails only on `main` but not on a branch | A `paths-ignore` filter difference | Not possible; check which commit the run used |

---

## Installing the IPA

| Symptom | Cause | Fix |
|---|---|---|
| `The maximum number of apps for free development profiles has been reached` | Three Sideloadly-installed apps already on the device | Delete one |
| `Your maximum App ID limit has been reached` | 10 App IDs registered in the last 7 days | Wait, or use a different Apple ID |
| `The executable was signed with invalid entitlements` (`0xE8008016`) | Signed entitlements do not match the provisioning profile | Re-run with **Remove Extensions off**. If it persists, re-download the IPA — it may have been modified in transit. Compare its SHA-256 with `sha256.txt` |
| App installs, will not launch | Not trusted | Settings ▸ General ▸ VPN & Device Management ▸ your Apple ID ▸ Trust |
| App launches but the Diagnostics screen says "This app bundle contains no PlugIns directory" | **Remove Extensions / Remove PlugIns** was enabled in Sideloadly | Reinstall with it off. That option deletes the entire tunnel |
| `PackageInspectionFailed` | The installer disliked the IPA structure | Run `Scripts/validate-ipa.sh ProxyTunnel.ipa` and compare with the CI validation report |
| `AppexBundleUnknownExtensionPointIdentifier` | The extension's `NSExtensionPointIdentifier` is wrong | Must be `com.apple.networkextension.packet-tunnel` |
| `AppexBundleIDNotPrefixed` | The extension's bundle identifier is not a child of the app's | Caused by bundle-ID rewriting. Set an explicit `bundle_id` in the workflow and in Sideloadly |
| Sideloadly does not see the device | Missing Apple device drivers | Install iTunes, or the Apple Devices app on Windows |
| The 2FA prompt loops | Anisette session expired | Restart Sideloadly; switch between Remote and Local Anisette if offered |
| Everything works, then the app stops launching after a week | Free provisioning profiles expire after 7 days | Re-run Sideloadly with the same IPA. Profiles and passwords survive |

---

## The tunnel will not start

### "iOS refused to save the VPN configuration (permission denied)"

**This is the expected outcome with a free Apple ID.** It is `NEVPNErrorDomain`
code 5, and it means the packet tunnel extension does not have
`com.apple.developer.networking.networkextension`.

Confirm it on **Settings ▸ Diagnostics ▸ Signing & entitlements**. If the
extension profile lists the entitlement as `ABSENT`, nothing in the app can fix
it. See [`ENTITLEMENTS-AND-SIGNING.md`](ENTITLEMENTS-AND-SIGNING.md).

If the entitlement **is** listed and you still get code 5, check:

* another VPN app already holds the active VPN configuration on the device —
  delete it in Settings ▸ General ▸ VPN & Device Management;
* the profile does not cover the **extension's** bundle identifier. The extension
  is a separate App ID and needs its own profile entry with Network Extensions
  enabled. This is a common self-inflicted cause.

### "iOS rejected the VPN configuration" (code 1)

The configuration is invalid. On a sideloaded build this usually means the same
thing as code 5. Otherwise: delete the ProxyTunnel entry in Settings ▸ General ▸
VPN & Device Management and reconnect from the app.

### "The VPN configuration was out of date" (code 4)

The configuration changed between saving and starting. Tap CONNECT again — the app
rewrites and reloads on every attempt.

### The VPN row exists in Settings but the toggle is greyed out

A configuration was created but the extension cannot be launched. That is the
entitlement again. There is no workaround.

### CONNECT does nothing

If the app shows **Connecting…** and never moves:

1. **Settings ▸ Logs** — filter to the `vpn` category. `startVPNTunnel() called`
   with nothing after it means the extension never started.
2. **Settings ▸ Logs ▸ Show the extension's log.** Empty means the extension
   process never ran, which points at the entitlement or at the extension not
   being present in the bundle.
3. Check that no other VPN is active. iOS allows one active VPN configuration.

### DISCONNECT does not disconnect

This was a real bug class and is handled: an on-demand "always connect" rule makes
iOS bring the tunnel straight back up. `TunnelController.disconnect()` clears the
rule, saves, *then* calls `stopVPNTunnel()`.

If it still reappears, something else — a configuration profile, or another VPN
app — is also asserting on-demand. Check Settings ▸ General ▸ VPN & Device
Management.

---

## The tunnel starts but nothing loads

**First, check whether it is actually carrying traffic.** The Connect screen shows
counters reported by the extension. If `TCP flows open` stays at zero while you
browse, the tunnel is up but carrying nothing — the status light is not evidence.

| Symptom | Likely cause | Fix |
|---|---|---|
| No counters move at all | Network settings were never applied. The Diagnostics "Network settings" row will say "not applied" | Check the extension log for a `setTunnelNetworkSettings` error. Another VPN holding routes is the usual cause |
| TCP flows open but every one fails immediately | The proxy credentials are wrong, or the proxy is unreachable **from the extension's transport** | Use **Test connection** first. If that works and the tunnel does not, see the next two rows |
| Every flow fails with an authentication error | The extension could not read the password | **Diagnostics ▸ Credential delivery**. `inline` with a username set means the App Group path failed and the fallback did not supply a password — re-save the proxy |
| Every flow fails with "proxy's own address (would loop)" | The excluded routes are missing, so the tunnel is trying to proxy its own transport | Should not happen; the engine also refuses it as a loop guard. Check the extension log for route installation warnings |
| Timeouts on every flow | The proxy requires connections from a whitelisted IP, and your carrier's IP is not on it | Check with your provider |
| Some sites work, others do not | The proxy blocks those destinations or ports | Check the failure kind in the log — `proxyRefusedConnection` carries the proxy's own reason |
| Nothing loads at all, and the network is IPv6-only | The proxy has only an IPv4 address | Nothing the app can do; use an IPv6-reachable proxy |
| Pages load but hang partway | Your proxy mishandles long-lived connections, or the half-close grace period expired | See [half-close](ARCHITECTURE.md#half-close-and-why-it-is-approximated) |
| Games, video calls and QUIC sites fail | You are using HTTP CONNECT or HTTPS, which cannot carry UDP | Switch to SOCKS5 |

### Everything is slow

Expected, to a degree: every TCP connection is terminated in userspace and
re-opened through a proxy, so it takes an extra round trip to the proxy to
establish. Beyond that:

* the userspace TCP stack has **no congestion control and no SACK**, so on a lossy
  link it will not recover as well as a kernel stack;
* the DNS-over-TCP path opens a fresh proxied connection **per query**;
* each proxied connection is a new TCP connection to the proxy — there is no
  connection pooling.

---

## DNS problems

| Symptom | Cause | Fix |
|---|---|---|
| "Cannot find server" / `NSURLErrorCannotFindHost` on everything | DNS servers are empty or invalid | Settings ▸ DNS. Must be IP literals. The validator will tell you |
| DNS works for some names, fails for others | Those names are being resolved by an app using encrypted DNS (DoH/DoT), which the tunnel does not intercept — it is proxied as ordinary traffic and may be blocked by the proxy | Nothing to fix in the app |
| Local device names (`.local`) do not resolve | mDNS is intercepted by the tunnel and cannot reach the local network | Use IP addresses, or exclude the local subnet |
| Very large DNS answers fail | Queries over 8 KiB are dropped, and fragmented IP packets are not reassembled | Usually a DNSSEC or large-TXT case. Nothing to fix in the app |
| `Diagnostics` shows DNS queries handled but failures climbing | The proxy cannot reach the resolver on port 53 | Change the DNS servers in Settings to ones the proxy can reach |

---

## The Test connection button

| Symptom | Meaning |
|---|---|
| "Proxy host not found" | `getaddrinfo` failed. Host name typo, or no working internet on the phone |
| "Proxy unreachable" with "connection refused" | Nothing is listening on that host:port. Check the port |
| "Proxy unreachable" with "network unreachable" | Your carrier is blocking that port, or the route is wrong |
| "Connection timed out" | Silently dropped — very often a firewall or carrier blocking a non-standard port. Try another port or another network |
| "TLS handshake with the proxy failed" | You selected **HTTPS CONNECT** but the endpoint is a plaintext HTTP proxy. Change the protocol to **HTTP CONNECT** |
| "Authentication failed" | The proxy rejected the username or password. Re-enter them — the app never shows or logs them |
| "Credentials required" | The proxy wants authentication and the profile has no username |
| "Unsupported authentication (method 0x01)" | The SOCKS5 proxy only offers GSSAPI. Use an endpoint that offers none or username/password |
| "Proxy refused the target connection" | Authentication worked, but the proxy would not reach the test host. Your plan may block port 80 |
| "Unreadable response" | The proxy relayed something that is not HTTP — usually an injected error page, or a proxy that blocks port 80 |
| Test succeeds but shows your real IP | You are not using a proxy you think you are. Check the host and port; some providers run both a proxy and a web server on the same host |

The probe deliberately uses **plain HTTP** to a well-known host so that the test
involves as little machinery as possible. If your proxy blocks port 80, change
the probe target in `Settings` (`probeHost` / `probePath` are in the settings
file) or use a proxy that does not.

---

## The app

| Symptom | Cause | Fix |
|---|---|---|
| "A password was saved for this proxy but the Keychain item is gone" | The app was restored to a new device. Keychain items are stored `ThisDeviceOnly` so they do not travel in a backup | Re-enter the password |
| The proxy list resets after a restore | `profiles.json` was restored but the Keychain items were not (by design) | Re-enter passwords |
| The app shows "MOCK CONNECTED" | Development / mock mode is on | Settings ▸ Development / mock mode. It never routes traffic; the banner says so |
| A warning banner says IPv6 is not routed | IPv6 routing is off, which is a leak rather than a block | Re-enable it, or accept it and understand the consequence |
| The Logs screen is empty | The minimum level filter | Change it to Trace |
| "Show the extension's log" is empty | Either the tunnel has not run, or the App Group container is unavailable | Check **Diagnostics ▸ Credential delivery**. Without an App Group the extension cannot mirror its log; use Console.app on a Mac |
| Copying the log exports a lot of text | By design — it is a bug-report attachment | Passwords are redacted at write time |

---

## When you need to report a problem

Include:

1. **Settings ▸ Diagnostics** — the whole screen, screenshots are fine.
2. **Settings ▸ Logs ▸ Copy all** — this includes the build and entitlement
   summary at the end, and the extension log when available.
3. The proxy protocol and the *shape* of the failure. **Never** paste your
   password: the app will not log it, but a screenshot of the edit form will show
   it.
4. Which signing route you used (free Apple ID via Sideloadly, paid account, …).

If the problem is with the build rather than the app, attach the
`ProxyTunnel-iOS-build-logs` artifact from the failed run.
