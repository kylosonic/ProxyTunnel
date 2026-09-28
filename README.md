# ProxyTunnel

An iOS app that routes your iPhone's traffic through a proxy you control, using a
real Network Extension packet tunnel — plus an honest account of exactly what iOS
will and will not let you do with it.

[![Build iOS IPA](https://github.com/kylosonic/ProxyTunnel/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/kylosonic/ProxyTunnel/actions/workflows/build-ipa.yml)

---

## Read this first

This project was built around a specific workflow: a Windows machine, no Mac, no
paid Apple Developer account, GitHub Actions producing an unsigned IPA, and
Sideloadly signing it with a free Apple ID.

**That workflow cannot run the VPN.** Not because of a bug in this code, but
because of an Apple licensing rule. To be precise about it:

| # | Milestone | Status |
|---|---|---|
| **A** | The Swift source compiles cleanly for iOS | ✅ **Verified** — both targets build unsigned on a GitHub macOS runner (Xcode 16.4) |
| **B** | An unsigned `ProxyTunnel.ipa` is produced | ✅ **Verified** — 1.8 MiB, arm64, validated structurally by [`Scripts/validate-ipa.sh`](Scripts/validate-ipa.sh) in CI and again independently; SHA-256 recorded as an artifact |
| **C** | Sideloadly signs it with a free Apple ID and installs it | ⚠️ Expected to work; **not verified by me** — I have no iPhone or Mac to test on |
| **D** | The packet tunnel extension is allowed to start on the iPhone | ❌ **Will fail.** `com.apple.developer.networking.networkextension` cannot be provisioned with a free Apple ID |
| **E** | Traffic is actually routed through your proxy | ❌ Fails for the same reason as D — *inside the tunnel*. The app's built-in connectivity test does prove the proxy itself works, under any signing method |

If you want D and E, you need the $99/year Apple Developer Program. There is no
legitimate way around it, and this project does not attempt one. The full
analysis, with sources, is in [`docs/ENTITLEMENTS-AND-SIGNING.md`](docs/ENTITLEMENTS-AND-SIGNING.md).

**What you get without paying, and it is genuinely useful:**

* a real SOCKS5 / HTTP CONNECT / HTTPS proxy client, written from the RFCs;
* a **Test connection** button that opens your proxy, requests a page through it,
  and reports the egress IP address the far end saw — proof your proxy and
  credentials work, verifiable from the phone;
* profile management with real validation and Keychain-backed credentials;
* full diagnostics: what your signature actually granted, what routes the tunnel
  installed, live packet and connection counters.

**What you get once you pay:** everything above, plus a working VPN. Nothing in
the source has to change — the tunnel is already implemented, not stubbed.

---

## Contents

- [What this actually is](#what-this-actually-is)
- [Quick start](#quick-start)
- [Installing the unsigned IPA with Sideloadly](#installing-the-unsigned-ipa-with-sideloadly)
- [Using the app](#using-the-app)
- [Proxy protocol support](#proxy-protocol-support)
- [DNS, IPv4 and IPv6](#dns-ipv4-and-ipv6)
- [Security and credentials](#security-and-credentials)
- [Development / mock mode](#development--mock-mode)
- [Repository layout](#repository-layout)
- [Building](#building)
- [Testing](#testing)
- [Known limitations](#known-limitations)
- [Documentation index](#documentation-index)
- [Licence](#licence)

---

## What this actually is

A SwiftUI app plus a `NEPacketTunnelProvider` extension. The extension is given
raw IP packets by iOS and has to do the work itself:

```
   iOS apps
      │  IP packets
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ ProxyTunnelExtension  (NEPacketTunnelProvider)                   │
│                                                                  │
│  NEPacketTunnelFlow ──► TunnelEngine                             │
│                          │                                       │
│                          ├─ TCPConnection ─┐  one proxied TCP    │
│                          │  (userspace TCP)│  stream per flow    │
│                          │                 ▼                     │
│                          ├─ SOCKS5 / HTTP CONNECT client         │
│                          │                                       │
│                          ├─ DNS interception (UDP or TCP DNS)    │
│                          └─ SOCKS5 UDP ASSOCIATE relay           │
└──────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                            your proxy ──► internet
```

There is no mock VPN screen. `CONNECT` creates a real `NETunnelProviderManager`
configuration, calls `saveToPreferences`, and calls `startVPNTunnel()`. If that
fails — and under free-Apple-ID signing it will — the app says so, explains why,
and shows you the evidence from its own provisioning profile.

That last part is unusual and worth calling out: **the app inspects its own
`embedded.mobileprovision` at runtime** and reports exactly which entitlements
survived signing (Diagnostics ▸ Signing & entitlements). iOS's own error for a
missing Network Extension entitlement is `NEVPNErrorDomain code 5 "permission
denied"`, which never mentions entitlements. This app tells you the truth
instead.

---

## Quick start

```bash
git clone https://github.com/kylosonic/ProxyTunnel.git
cd ProxyTunnel

# On a Mac only — GitHub Actions does this for you.
brew install xcodegen
xcodegen generate
open ProxyTunnel.xcodeproj
```

To produce the IPA without a Mac:

1. Push to `master`, or open **Actions ▸ Build iOS IPA ▸ Run workflow**.
2. Wait for the green tick (roughly 10–15 minutes on a cold runner).
3. Download the **`ProxyTunnel-iOS-unsigned`** artifact.
4. Unzip it — you get `ProxyTunnel.ipa`.
5. Follow [Installing the unsigned IPA with Sideloadly](#installing-the-unsigned-ipa-with-sideloadly).

Before you first build, **change the bundle identifier prefix** to something only
you will use — here is why and how:

> Free Apple ID signing registers App IDs *globally*. If somebody else has already
> registered `io.github.kylosonic.proxytunnel`, your install will fail with
> "maximum App ID limit reached" or a duplicate-identifier error. Edit
> `BUNDLE_ID_BASE` in [`project.yml`](project.yml), or pass it to the workflow's
> `bundle_id` input.

---

## Installing the unsigned IPA with Sideloadly

This is the workflow the project was designed for.

### Before you start

* **Sideloadly** installed on Windows or macOS, from <https://sideloadly.io>.
* An iPhone with iOS 16 or later, connected by cable, **trusted** on the computer.
* Your **Apple ID** (a free one is fine) and its password. If your account has
  two-factor authentication, have your second device ready.
* The `ProxyTunnel.ipa` from the Actions artifact.

### The steps

1. **Trigger the build.** Push to `master`, or **Actions ▸ Build iOS IPA ▸ Run
   workflow ▸ Run workflow**. Optionally set `bundle_id` to your own prefix.

2. **Wait for it.** The run takes about 10–15 minutes. The **Validate the IPA**
   step prints a full report of the bundle structure.

3. **Download the artifact.** On the finished run page, scroll to **Artifacts**
   and download **`ProxyTunnel-iOS-unsigned`**. Unzip it → `ProxyTunnel.ipa`.
   Also grab **`ProxyTunnel-iOS-build-logs`** if anything goes wrong.

4. **Open Sideloadly.** Leave the device connected.

5. **Select the IPA.** Drag `ProxyTunnel.ipa` onto the Sideloadly window, or use
   the IPA field's file picker.

6. **Enter your Apple ID.** Type it into the **Apple ID** field. Sideloadly
   connects to Apple to register the App ID and obtain a 7-day provisioning
   profile.

   > **Do not** enable **Remove Extensions** / **Remove PlugIns**. That option
   > deletes `PlugIns/ProxyTunnelExtension.appex`, which is the entire tunnel. If
   > you turn it on, the app will still install but there will be no Network
   > Extension at all — and the app's Diagnostics screen will report
   > "This app bundle contains no PlugIns directory".

7. **Start.** Click **Start** and enter your Apple ID password when prompted.
   Sideloadly signs the app, then signs and installs the extension.

8. **Install and trust.** The app appears on the Home Screen. On the iPhone, go
   to **Settings ▸ General ▸ VPN & Device Management ▸ Developer App**, tap your
   Apple ID, and choose **Trust**.

9. **Open the app** and confirm what you have. Go to **Settings ▸ Diagnostics ▸
   Signing & entitlements**. You will see one of:
   * the extension profile lists `com.apple.developer.networking.networkextension`
     → you have a paid account, or something unexpected happened; the tunnel
     should work;
   * the extension profile is present but that key is **absent** → this is the
     expected outcome for a free Apple ID, and the tunnel cannot start.

10. **Test the proxy anyway.** Add a proxy on the **Proxies** tab and tap **Test
    connection**. This does a real end-to-end check that bypasses the VPN
    entirely: it opens your proxy, asks it to reach a well-known host, sends an
    HTTP request through the tunnel, and shows you the IP address the far end
    saw. If you see your proxy's egress IP, your proxy and credentials are
    correct.

11. **Try CONNECT** if you like. It will create the VPN configuration and then
    fail, with an explanation rather than a shrug.

### What to expect afterwards

* The app works. Profiles, validation, Keychain storage, diagnostics and the
  connectivity test all function.
* The tunnel does not. `CONNECT` will report **"iOS refused to save the VPN
  configuration (permission denied)"** and point at the Diagnostics screen.
* You may see a **VPN** row in Settings that is present but permanently unusable,
  or no row at all. Both are normal.
* **The app expires after 7 days.** Free provisioning profiles last a week; just
  run Sideloadly again with the same IPA.
* Free accounts can register **10 App IDs which expire after 7 days**, install
  **up to 3 apps per device**, and register **up to 3 devices**. An app with an
  extension uses more than one App ID.

### If you later buy a Developer Program membership

Nothing in the source changes. The same IPA, signed with a paid certificate and a
profile that includes the Network Extensions capability, gets a working tunnel.
See [`docs/SIGNED-BUILDS.md`](docs/SIGNED-BUILDS.md) for the CI job to add.

---

## Using the app

### Connect tab

Large CONNECT / DISCONNECT button, the live state, the selected proxy, the
protocol, the endpoint, the connection duration and — when the tunnel is actually
running — counters reported by the extension itself: open TCP flows, bytes
proxied in each direction, DNS queries handled.

The state shown is derived from `NEVPNStatus` plus the extension's own status
payload. The UI never invents a state.

### Proxies tab

Add, edit, delete, enable/disable and select proxy profiles. Each profile stores
a name, host, port, protocol, optional username and password, and free-form
notes.

#### Pasting a proxy instead of typing it

**+** ▸ **Paste from clipboard…** accepts whatever your provider gave you, and
shows what it understood before anything is saved. All of these work, mixed
together, one per line:

```
# ProxyCheap — Germany
socks5://example-user:example-password@203.0.113.7:1080
198.51.100.9:8080:example-user:example-password
example-user:example-password@198.51.100.9:1080
198.51.100.9:1080@example-user:example-password
203.0.113.7:1080
203.0.113.7 1080 example-user example-password
host=203.0.113.7 port=1080 user=example-user pass=example-password
server:203.0.113.7:port:1080:username:example-user:password:example-password
Frankfurt | socks5://example-user:example-password@203.0.113.7:1080
{"host":"203.0.113.7","port":1080,"username":"example-user","password":"example-password"}
[{"host":"…","port":1080}, {"host":"…","port":8080,"protocol":"http"}]
```

`http://` and `https://` map to the HTTP CONNECT and HTTPS CONNECT protocols;
`socks5h://` and `socks://` map to SOCKS5. Blank lines and lines starting with
`#`, `//` or `;` are ignored, so a comment header can be pasted with the list.

Every line gets a verdict. Anything that could be read two ways — `a:b:c:d` is
genuinely ambiguous — says which reading was assumed, so a wrong guess is visible
before you save it. **Skip proxies I already have** (on by default) matches on
host, port and protocol, so re-pasting a list after your provider rotates
passwords changes nothing.

Passwords go straight to the Keychain on Add. They are masked on the paste
screen, never written to the app's logs, and the parsed proxy then goes through
exactly the same validator the manual form uses.

The **Test connection** button on the edit screen remains the way to prove a
proxy actually works. It performs a real end-to-end check and reports:

```
Proxy host resolved to 203.0.113.7
TCP connect to 203.0.113.7:  OK (84 ms)
Proxy handshake: SOCKS5 CONNECT succeeded (61 ms)
HTTP request through the proxy: status 200
Traffic exited via 198.51.100.4
```

That last line is your proxy's egress address, served by the origin server. It is
not simulated.

### Settings tab

* **Connect on launch**
* **Block traffic while the tunnel is down** — installs an iOS on-demand rule
  (see [Known limitations](#known-limitations))
* **DNS servers** — validated as IP literals
* **Route IPv6 through the tunnel**
* **Relay UDP through SOCKS5**
* **Connection idle timeout**
* **Development / mock mode**
* **Log every packet** — very noisy, off by default
* **Diagnostics**, **Logs**, **About & limitations**

---

## Proxy protocol support

Verified against the implementations in
`Packages/ProxyTunnelCore/Sources/ProxyTunnelCore/Proxy/`.

| | SOCKS5 | HTTP CONNECT | HTTPS CONNECT |
|---|---|---|---|
| **TCP** | ✅ full tunnelling | ✅ full tunnelling | ✅ full tunnelling |
| **UDP** | ✅ via UDP ASSOCIATE (RFC 1928 §7) | ❌ none possible | ❌ none possible |
| **DNS** | ✅ over the UDP relay | ✅ terminated in-tunnel, re-issued as DNS-over-TCP | ✅ same |
| **IPv4 targets** | ✅ | ✅ | ✅ |
| **IPv6 targets** | ✅ if the proxy supports it | ✅ if the proxy supports it | ✅ if the proxy supports it |
| **Remote name resolution** | ✅ | ✅ | ✅ |
| **Credentials** | RFC 1929 | Basic, pre-emptive | Basic, pre-emptive |
| **Transport encryption** | ❌ none | ❌ none | ✅ TLS to the proxy |

**SOCKS5 is the recommended protocol.** It is the only one of the three that can
carry UDP, which matters for QUIC/HTTP-3, games, VoIP and some VPN protocols.

Limitations of each, stated plainly:

* **SOCKS5** — no encryption of its own. Credentials and payload are in the clear
  between your phone and the proxy unless the network path is otherwise
  protected. UDP fragmentation (`FRAG != 0`) is optional in RFC 1928, is almost
  never implemented, and is **dropped** by this client rather than silently
  mangled.
* **HTTP CONNECT** — no datagram relay exists in the protocol, so non-DNS UDP is
  dropped. QUIC, HTTP/3 and UDP-based games will not work. Credentials use HTTP
  Basic inside a plaintext request unless you use an HTTPS proxy.
* **HTTPS CONNECT** — same UDP limitation. The certificate is validated against
  the system trust store using the proxy hostname as the SNI and verification
  name. This is *not* the same thing as an HTTP proxy that happens to listen on
  port 443.

See [`docs/PROXY-PROTOCOLS.md`](docs/PROXY-PROTOCOLS.md) for the long version.

---

## DNS, IPv4 and IPv6

### DNS

DNS is not delegated to the system resolver. The tunnel advertises its own
resolvers to iOS, intercepts every query arriving on port 53, and re-issues it
through the proxy:

* with **SOCKS5**, over the UDP association;
* with **HTTP CONNECT / HTTPS**, as DNS-over-TCP (RFC 7766) inside a proxied
  stream, so it works even though the protocol cannot carry datagrams.

No DNS packet reaches the resolver your carrier or the local Wi-Fi network handed
you. There is no second, supplemental resolver configured.

The DNS message itself is never parsed — the query is forwarded as opaque bytes
and the answer returned verbatim, so EDNS0, DNSSEC records and future extensions
pass through untouched.

**Honest caveats.** Queries larger than 8 KiB are dropped rather than
fragmented. The DNS-over-TCP path opens one proxied connection per query, which
is correct but not cheap. Encrypted DNS (DoH/DoT) started by an app is *not*
intercepted — it is proxied like any other connection, which is fine because it
is already encrypted. And a proxy operator can see every name you look up; that
is inherent to using a proxy for DNS.

### IPv4

The tunnel captures `0.0.0.0/0` and adds each of the proxy's resolved IPv4
addresses as a `/32` exclusion, so the tunnel's own transport does not loop back
inside itself. The app resolves the proxy hostname *before* the tunnel starts —
inside the tunnel there is no DNS until the tunnel is up, which is exactly the
chicken-and-egg problem the exclusion list solves.

### IPv6

IPv6 is captured too (`::/0`, proxy addresses excluded as `/128`), for the same
reason: on an IPv6-only carrier network, not routing IPv6 means no connectivity
at all, and on a dual-stack network it means a leak.

**But**: an IPv4-only proxy cannot reach IPv6 destinations. Connections to IPv6
literals will fail at the proxy. That is a property of your proxy, not of this
app. If it happens repeatedly, the tunnel logs a one-time note suggesting you
disable IPv6 in Settings. Turning IPv6 off does not block it — IPv6 traffic
simply leaves the tunnel, and the Diagnostics screen says so in as many words.

DNS64/NAT64 networks (some carriers) synthesise IPv6 addresses for IPv4-only
destinations. Those work through the tunnel as ordinary IPv6 connections and the
proxy resolves them as such.

### What is deliberately not implemented

* **IP fragment reassembly.** Fragmented packets are dropped and counted. Almost
  every fragmented packet on a phone is a large UDP datagram; a TCP connection
  is unaffected because the tunnel terminates it.
* **TCP congestion control and SACK.** The tun interface is not a bottleneck and
  the proxy link has its own congestion control. Retransmission, window scaling,
  flow control, fast retransmit, zero-window probes and graceful close *are*
  implemented.
* **Half-close through the proxy.** Neither SOCKS5 nor HTTP CONNECT can signal
  "the client has finished writing" other than by closing the whole stream. When
  the app half-closes, the tunnel keeps reading from the proxy and waits for the
  far end, bounded by a 120-second grace period.

---

## Security and credentials

**Passwords never touch this repository, this app's files, `UserDefaults`, or any
log.**

* `ProxyProfile` has **no password property at all** — only a `passwordReference`
  pointing into the Keychain. There is no field that *could* hold a secret, so
  the guarantee is structural rather than a matter of discipline.
* Passwords live in the **iOS Keychain** as `kSecClassGenericPassword` items with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — bound to the device, so
  they are not carried by an iCloud or backup restore.
* The profile JSON is written with `NSFileProtectionComplete`.
* Every log line passes through `LogRedactor`, which scrubs `user:pass@host`,
  `password=`, `Proxy-Authorization`, RFC 1929 dumps and long base64 blobs before
  anything is stored or handed to `os_log`.
* `ProxyCredential.description`, `ProxyProfile.description` and
  `TunnelConfiguration.redactedSummary` are all redacted, so an accidental string
  interpolation in a log statement cannot leak.
* The extension's copy of the credential is dropped from memory when the tunnel
  stops.

### How the password reaches the extension

Three options, and the app picks the best available one **at runtime**, then
tells you which it used on the Diagnostics screen:

1. **App Group shared container** (preferred). The app writes the credential to
   `group.<bundle-id>` with `NSFileProtectionComplete`; the extension reads it. It
   never enters the system VPN preferences. App Groups is one of the few
   capabilities a free Apple ID *can* provision.
2. **Shared Keychain access group** — same idea, needs the Keychain Sharing
   capability and a matching team identifier.
3. **Inline in `NETunnelProviderProtocol.providerConfiguration`** (fallback).
   Works with no entitlements at all, but iOS persists that dictionary in the
   system VPN preferences, outside the app sandbox. The app warns when it has to
   do this.

The app checks the **extension's own provisioning profile** to decide whether the
App Group is usable, because a partial strip (app gets the entitlement, extension
does not) would produce a tunnel that starts and then mysteriously fails to
authenticate.

### What is never claimed

* No "zero DNS leaks" claim. The design prevents queries from reaching the
  physical network's resolver, and that is verified by the in-tunnel
  interception, but it has not been measured against a live packet capture on a
  device.
* No "kill switch" claim beyond the specific iOS on-demand behaviour described in
  [Known limitations](#known-limitations).
* No claim that a proxy is a privacy tool. Your proxy operator sees every
  destination you connect to.

---

## Development / mock mode

Settings ▸ Development / mock mode replaces the VPN connection with a
clearly-labelled simulation, so the interface can be exercised on a build where
the packet tunnel extension cannot run.

It follows three rules, enforced in `MockTunnelSession`:

* the banner reads **MOCK / DEVELOPMENT MODE — no VPN tunnel exists and no traffic
  is being routed** on every screen that shows connection state;
* the headline reads **MOCK CONNECTED**, never "Connected";
* it has **no statistics**. There are no counters that could be misread as real
  traffic, and it never touches `NetworkExtension`.

It is a labelled development affordance, not a fake VPN.

---

## Repository layout

```
.
├── .github/workflows/build-ipa.yml   CI: generate, build, test, package, validate
├── Config/                           Info.plist and entitlements for both targets
│   ├── ProxyTunnel-Info.plist
│   ├── ProxyTunnel.entitlements
│   ├── ProxyTunnelExtension-Info.plist
│   └── ProxyTunnelExtension.entitlements
├── Packages/ProxyTunnelCore/         All the logic, as a local Swift package
│   └── Sources/ProxyTunnelCore/
│       ├── Models/                   ProxyProfile, ProxyCredential, failures, state
│       ├── Proxy/                    SOCKS5, HTTP CONNECT, transport, probe, resolver
│       ├── Tunnel/                   Userspace TCP/IP stack, engine, DNS, UDP relay
│       ├── Validation/               Host, port, profile and DNS validation
│       ├── Security/                 Keychain secret storage
│       ├── Storage/                  Profile and settings persistence
│       ├── Diagnostics/              Redacting log, entitlement inspector
│       └── Support/                  IP addresses, byte buffers, shared container
├── Sources/ProxyTunnelApp/           SwiftUI app
├── Sources/ProxyTunnelExtension/     NEPacketTunnelProvider
├── Tests/ProxyTunnelCoreTests/       Unit + loopback integration tests
├── Scripts/                          XcodeGen install, IPA packaging and validation
├── docs/                             Architecture, entitlements, protocols, testing
└── project.yml                       XcodeGen spec — the .xcodeproj is generated
```

**No `.xcodeproj` is committed.** It is generated from `project.yml`, which means
no machine-specific absolute paths in version control, no unmergeable project
file conflicts, and a build that is reproducible on a clean CI machine with
nothing installed but Xcode and XcodeGen.

`ProxyTunnelCore` is a **static** library product on purpose: the app and the
extension each link their own copy into their own Mach-O image, so the bundle
contains no embedded framework. That matters when the IPA is re-signed by a
third-party tool — fewer nested code objects means fewer things that can go
wrong.

---

## Building

Nothing here requires a Mac *you own*.

### On GitHub Actions (no Mac)

Push, or **Actions ▸ Build iOS IPA ▸ Run workflow**. Inputs:

| Input | Default | Meaning |
|---|---|---|
| `bundle_id` | `io.github.kylosonic.proxytunnel` | Bundle identifier base. **Change this.** |
| `configuration` | `Release` | Build configuration |
| `run_tests` | `true` | Run the simulator test suite |

Artifacts:

| Artifact | Contents |
|---|---|
| `ProxyTunnel-iOS-unsigned` | `ProxyTunnel.ipa` + SHA-256 + provenance + validation report |
| `ProxyTunnel-iOS-build-logs` | Full `xcodebuild` output for both targets, test results, toolchain and simulator listings |

The workflow generates the project, resolves packages, builds the app and the
extension **unsigned**, runs the tests on a simulator, packages the IPA, and then
validates it: ZIP integrity, `.app` presence, `arm64` slice, `PlugIns/*.appex`,
extension point identifier, `XPC!` package type, bundle-identifier nesting, and
the absence of any signing material.

### On a Mac

```bash
brew install xcodegen
xcodegen generate
open ProxyTunnel.xcodeproj
```

To build the unsigned IPA by hand:

```bash
xcodebuild build \
  -project ProxyTunnel.xcodeproj \
  -scheme ProxyTunnel \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

./Scripts/make-ipa.sh build/DerivedData/Build/Products/Release-iphoneos/ProxyTunnel.app ProxyTunnel.ipa
./Scripts/validate-ipa.sh ProxyTunnel.ipa
```

See [`docs/BUILDING.md`](docs/BUILDING.md) for details, including how to add
signing later.

---

## Testing

215 tests, split into two batches in CI so that a slow one cannot hide the other's
result: **208 pass, 7 skip.**

| Batch | Contents | Result |
|---|---|---|
| Logic | Validation, models, codecs, storage | **147 passing** |
| Integration | TCP state machine, tunnel engine, live proxies, Keychain | **61 passing, 7 skipped** |

The **live-proxy tests really do run in CI**: a SOCKS5 server and an HTTP CONNECT
server are started on loopback inside the test process, and the production client
is driven against them — real handshakes, real credentials, real relayed bytes,
and a full tunnel round trip that feeds a synthetic SYN into the engine and checks
that the echoed payload comes back out as TCP packets.

The 7 skipped tests are the Keychain round trips. iOS derives an app's keychain
access group from its code signature, and a host-less test bundle on the Simulator
has none, so those tests skip with the reason rather than fail. They run on a
device or under Xcode with a signed test host.

**The suite has already earned its keep.** It found, among others: a TCP header
serialiser that omitted the checksum field and shifted every option and payload
byte by two; a SOCKS5 CONNECT request with a duplicated address-type byte; and a
proxy handshake object that was deallocated mid-flight because every callback
captured it weakly — which on a device would have made the tunnel start, install
its routes, and carry nothing. The full list is in
[`docs/TESTING.md`](docs/TESTING.md#bugs-this-suite-found).

**What the tests do not prove.** They cannot show that the packet tunnel starts on
a device — that needs the Network Extension entitlement, which a CI simulator does
not enforce. They cannot validate against a real provider endpoint, because that
needs real credentials; only the app's **Test connection** button can do that.

---

## Known limitations

Ordered roughly by how likely they are to matter.

1. **The tunnel needs a paid Apple Developer Program membership.** Covered
   exhaustively in [`docs/ENTITLEMENTS-AND-SIGNING.md`](docs/ENTITLEMENTS-AND-SIGNING.md)
   and summarised at the top of this file.

2. **"Block traffic while the tunnel is down" is iOS's on-demand behaviour, not a
   firewall.** It installs an `NEOnDemandRuleConnect` rule with
   `interfaceTypeMatch = .any`, which makes iOS hold traffic and re-establish the
   tunnel after a drop. It is iOS's own fail-closed mechanism. It is *not* a
   desktop-style kill switch: it cannot stop traffic that was already established
   over the physical interface before the tunnel came up, and it is not a packet
   filter. The Settings screen says this in full.

3. **Non-DNS UDP does not work through HTTP CONNECT or HTTPS proxies.** The
   protocols have no datagram relay. QUIC, HTTP/3 and UDP games will not work.
   DNS still does, via DNS-over-TCP.

4. **Fragmented IP packets are dropped**, not reassembled.

5. **IPv4-only proxies cannot reach IPv6 destinations**, and IPv6-only proxies
   cannot reach IPv4 destinations. This surfaces as connection failures from the
   proxy, not as a tunnel bug.

6. **Half-close is approximated** with a 120-second grace period, because SOCKS5
   and HTTP CONNECT cannot carry it.

7. **No congestion control or SACK** in the userspace TCP stack. On a lossy radio
   link this makes throughput worse than a kernel stack would achieve.

8. **The proxy sees everything.** Destinations, timing, traffic volume, and the
   contents of any plaintext protocol. A proxy is not a VPN in the privacy sense,
   and the app's About screen says so.

9. **App Group availability under a free Apple ID is unverified in practice.**
   Apple's capability table marks App Groups as available to free accounts, but
   whether a sideloading tool provisions it is not documented anywhere I could
   find. The app detects this at runtime and falls back to an inline credential.
   See [`docs/research/`](docs/research/) for the primary sources.

10. **`com.apple.developer.networking.vpn.api` ("Personal VPN") is not needed** for
    a packet tunnel — only for the legacy `NEVPNManager`/IKEv2 API. This project
    does not request it. Older advice saying "you need both" is stale.

---

## Documentation index

| Document | Contents |
|---|---|
| [`docs/ENTITLEMENTS-AND-SIGNING.md`](docs/ENTITLEMENTS-AND-SIGNING.md) | **The important one.** Which entitlement is required, why a free Apple ID cannot provision it, what happens at runtime, what Sideloadly does and does not do, and what a paid account changes |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Component-by-component design, threading model, packet flow, the loop-avoidance problem |
| [`docs/PROXY-PROTOCOLS.md`](docs/PROXY-PROTOCOLS.md) | Capability matrix with the reasoning, and per-protocol limitations |
| [`docs/DNS-AND-IP.md`](docs/DNS-AND-IP.md) | DNS interception design, IPv4/IPv6 routing, DNS64/NAT64 |
| [`docs/BUILDING.md`](docs/BUILDING.md) | Local and CI builds, XcodeGen, changing the bundle identifier, runner images |
| [`docs/SIDELOADLY.md`](docs/SIDELOADLY.md) | The install workflow in detail, including every way it can go wrong |
| [`docs/SIGNED-BUILDS.md`](docs/SIGNED-BUILDS.md) | The CI job to add if you get a Developer Program membership, and where each secret goes |
| [`docs/TESTING.md`](docs/TESTING.md) | What is tested, what is not, and why |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Symptom → cause → fix |
| [`docs/research/`](docs/research/) | The primary-source research behind the entitlement claims, with verbatim quotes, URLs and confidence labels |

---

## Licence

MIT. See [`LICENSE`](LICENSE).

The licence notice also records, in the project's own words, that running a
Packet Tunnel Provider requires an entitlement this project cannot obtain for
you, and that the project does not attempt to circumvent Apple's entitlement or
code-signing system.
