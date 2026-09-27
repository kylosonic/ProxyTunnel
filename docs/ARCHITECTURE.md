# Architecture

## The problem

iOS does not let an app open a proxy connection on behalf of other apps. The only
supported mechanism is a Network Extension with a Packet Tunnel Provider, and
that gives you something considerably lower-level than a socket: **raw IP
packets**.

SOCKS5 and HTTP CONNECT carry **byte streams**. So the extension has to bridge
between the two — which means terminating TCP itself, in userspace, for every
connection the phone makes.

That is the whole shape of this project.

```
                    ┌──────────────────────────────────────────┐
   iOS apps ──────► │  utun interface (10.7.0.1 / fd00:7:7:7::1)│
                    └──────────────────┬───────────────────────┘
                                       │ IP packets
                    ┌──────────────────▼───────────────────────┐
                    │  NEPacketTunnelFlow                      │
                    └──────────────────┬───────────────────────┘
                                       │
┌──────────────────────────────────────▼───────────────────────────────────┐
│ ProxyTunnelExtension                                                     │
│                                                                          │
│   TunnelEngine                     one serial DispatchQueue               │
│     ├── flow table                  [TCPFlowKey: TCPConnection]          │
│     ├── UDP flow table              [UDPFlowKey: lastSeen]               │
│     ├── SOCKS5UDPRelay              (SOCKS5 only)                        │
│     └── DNSTunnelResolver           UDP relay  or  DNS-over-TCP          │
│                                                                          │
│   TCPConnection  (one per connection)                                    │
│     ├── userspace TCP state machine                                      │
│     ├── reassembly + out-of-order queue                                  │
│     ├── retransmission, window scaling, persist probes                    │
│     └── one ProxyConnection ──► SOCKS5 / HTTP CONNECT ──► the proxy       │
└──────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
                              your proxy ──► internet
```

---

## Targets

### `ProxyTunnel` — the main app

SwiftUI, three tabs. Owns:

* the proxy profile store and its JSON document;
* Keychain access for passwords;
* `NETunnelProviderManager` lifecycle;
* connection state derived from `NEVPNStatus` plus the extension's status
  payload;
* the connectivity probe;
* diagnostics, logs and the entitlement inspection.

It never opens the tunnel itself, and it never fakes a state.

### `ProxyTunnelExtension` — the packet tunnel

`NEPacketTunnelProvider`. Owns the engine, the packet flow and the proxy
transport. Its job, in order:

1. decode the `TunnelConfiguration` from `providerConfiguration`;
2. obtain the proxy credential;
3. build and install `NEPacketTunnelNetworkSettings` (routes, DNS, MTU);
4. create and start `TunnelEngine`.

Step 3 **must** complete before step 4. Reading packets before the settings are
applied yields a flow that is not attached to anything: the tunnel appears to run
and carries nothing.

### `ProxyTunnelCore` — a local Swift package

Everything that is not UI, so that it can be unit-tested and so that the app and
the extension share exactly one implementation of every protocol.

It is a **static** library product. Both targets link their own copy into their
own Mach-O image, so the app bundle contains no embedded framework. That is not
an optimisation — it matters when the IPA is re-signed by a third-party tool,
because fewer nested code objects means fewer things that can go wrong.

---

## Threading model

There is one rule: **every field of `TunnelEngine` and `TCPConnection` is
confined to a single serial `DispatchQueue`, and nothing calls into them from
another thread.**

```
                    ┌────────────────────────────────────────┐
  NEPacketTunnelFlow│  engineQueue (serial)                  │
  .readPackets ─────►  handlePacket → handleTCP/handleUDP    │
                    │       │                                │
  NEPacketTunnelFlow│       ├─► TCPConnection.handleInbound   │
  .writePackets ◄───┤       │        │                       │
                    │       │        └─► ProxyConnector ─────┼──► NWConnection callbacks
                    │       │             (callbacks hop back│    are delivered on engineQueue
                    │       │              onto engineQueue) │
                    │       └─► PacketWriteCoalescer ────────┼──► batched writes
                    │                                        │
                    │  DispatchSourceTimer / asyncAfter ─────┘
                    └────────────────────────────────────────┘
```

Consequences worth stating:

* **No locks anywhere in the engine.** There is nothing to get wrong.
* `NWConnection` is created with an explicit callback queue — the same engine
  queue — so proxy callbacks arrive serialised with packet processing.
* Timers are `DispatchWorkItem`s scheduled with `asyncAfter` on that queue.
* `PacketWriteCoalescer` batches writes for up to 5 ms or 32 packets, because
  every `writePackets` call crosses into the kernel.

The app side uses `@MainActor` classes and `async`/`await`, which is the natural
fit for SwiftUI. The two worlds meet only through the `NETunnelProviderSession`
message channel.

---

## The app ⇄ extension channel

`NETunnelProviderSession.sendProviderMessage` carries opaque `Data`. Everything
crossing it is Codable JSON with an explicit schema version, so a stale extension
from a previous install cannot be misread.

```
TunnelRequestEnvelope   { schemaVersion, kind: status | clearLog | setTracePackets | ping, tracePackets? }
TunnelResponseEnvelope  { schemaVersion, status: TunnelStatusPayload?, error: String? }
```

`TunnelStatusPayload` carries the engine state, `connectedSince`, the full
`TunnelStatistics`, the last failure, whether network settings were applied, the
routing description, the UDP relay description, the physical interface in use,
and the tail of the extension's log.

The app polls it once per second while connected. That is what makes the
counters on the Connect screen real rather than decorative.

---

## Lifecycle

### Connecting

```
User taps CONNECT
  │
  ├─ 0. entitlement check          ← from the app's own provisioning profile
  │     if definitively missing → fail immediately, explain, stop
  │
  ├─ 1. resolve the proxy host     ← in the APP, before the tunnel exists
  │
  ├─ 2. build TunnelConfiguration
  │     · resolved addresses, so the extension never does DNS
  │     · credential delivery: shared container → inline → none
  │
  ├─ 3. NETunnelProviderManager
  │     · find ours by providerBundleIdentifier, or create one
  │     · NETunnelProviderProtocol with providerConfiguration
  │     · on-demand rule if "block traffic while down" is on
  │     · saveToPreferences → loadFromPreferences   (both required)
  │
  └─ 4. startVPNTunnel()
        │
        └─ extension: startTunnel(options:completionHandler:)
             ├─ decode configuration
             ├─ resolve credential
             ├─ start the physical-interface monitor
             ├─ setTunnelNetworkSettings(...)   ← installs the routes
             └─ engine.start()                  ← begins reading packets
```

### Disconnecting

`NEOnDemandRuleConnect` with `interfaceTypeMatch = .any` means "always connect".
Leaving it enabled while calling `stopVPNTunnel()` makes DISCONNECT appear to do
nothing, because iOS brings the tunnel straight back up. A genuinely confusing
bug in a lot of VPN apps.

So `disconnect()` does this, in order:

1. clear `isOnDemandEnabled` and `onDemandRules`, save;
2. `stopVPNTunnel()`;
3. reset state.

CONNECT re-installs the rule.

### App restart

`loadAllFromPreferences` finds the existing configuration by bundle identifier
and reports what iOS thinks its status is. The manager is never recreated from
scratch if one already exists — doing so would orphan the system's VPN profile.

---

## The userspace TCP stack

`TCPConnection` implements the client half of TCP for the subset a proxy tunnel
needs.

### Implemented

| Concern | Approach |
|---|---|
| Passive open | Answer the app's SYN with a SYN-ACK carrying MSS and a window-scale option |
| ISN selection | Random per connection, mixed with the clock. Not a cryptographic guarantee, and documented as such |
| Receive reassembly | In-order delivery with a bounded out-of-order map keyed by sequence number, drained on each advance |
| Duplicate handling | Trim the already-acknowledged prefix, re-ACK, count it |
| Send window | Honour the app's advertised window, scaled by the negotiated shift |
| Window scale | Negotiated in the SYN-ACK (shift 7, giving an 8 MiB maximum window) |
| Retransmission | Single timer for the oldest unacknowledged segment, RFC 6298-style exponential backoff, capped at 8 s, then give up |
| Fast retransmit | Three duplicate ACKs |
| Zero window | Persist timer sends a bare ACK probe every 2 s |
| Flow control | Advertised window shrinks as the in-to-proxy buffer fills, so a slow proxy throttles the app |
| Back-pressure | The tunnel stops reading from the proxy stream while the app is behind |
| Graceful close | FIN in both directions, 5 s linger to absorb a retransmitted final ACK |
| Idle timeout | 30 minutes by default, configurable |

### Deliberately not implemented

* **Congestion control.** The tun interface is not a bottleneck and the proxy
  link has its own. On a lossy radio link this means throughput is worse than a
  kernel stack would achieve.
* **SACK.** Not advertised, because it is not processed. Cumulative ACKs plus RTO
  recovery still work; loss recovery is just slower.
* **TCP timestamps.** Optional, and most stacks handle their absence.
* **Path MTU discovery.** The tunnel sets a fixed MTU and derives MSS from it.
* **Half-close.** Neither proxy protocol can carry it (see below).

### Half-close, and why it is approximated

`shutdown(SHUT_WR)` has no equivalent in SOCKS5 CONNECT or HTTP CONNECT. There is
no way to tell the origin "the client has finished writing" other than by closing
the whole stream — which would truncate the response.

So when the app half-closes, the tunnel:

1. stops accepting new data from the app;
2. flushes what it has to the proxy;
3. **keeps reading** from the proxy until EOF;
4. sends its own FIN to the app;
5. gives up after `halfCloseGraceTimeout` (120 s) if the far end never closes.

Most request/response protocols work fine. A protocol that genuinely needs the
origin to observe the half-close will not.

---

## The loop-avoidance problem

This is the subtle one, and getting it wrong produces a tunnel that hangs
immediately.

Once the tunnel installs a default route, a socket opened **inside the
extension** would send its packets to the proxy *through the tunnel* — back to
itself. Every real VPN client solves this in one of two ways; this one does both.

### 1. Exclude the proxy's addresses from the tunnel routes

The app resolves the proxy hostname **before** the tunnel exists, using the
physical network's DNS, and passes the address list to the extension in
`TunnelConfiguration.resolvedProxyAddresses`. The extension adds each one to
`excludedRoutes` as a `/32` or `/128`.

This also solves a chicken-and-egg problem: inside the tunnel there is no DNS
until the tunnel is up, so the extension must never resolve the proxy's own name.
It doesn't — it dials IP literals only.

> Free-Apple-ID sideloading tools are documented as sometimes rewriting the
> bundle identifier. If that happened to the *proxy hostname*, nothing would
> break, because the resolution happens fresh every time you tap CONNECT.

### 2. Bind the transport to the physical interface

`PhysicalInterfaceResolver` runs three `NWPathMonitor`s — Wi-Fi, cellular and
wired — and exposes the best available `NWInterface`. `NWInterface` has no public
initialiser, so a path is the only way to obtain one.

`NWByteStream` sets `NWParameters.requiredInterface` to it, pinning the proxy
connection to the real network. If no interface is available yet, the excluded
routes alone are correct — the fallback is safe, not broken.

### 3. Refuse anything that would still loop

`TunnelEngine.blockedReason(for:)` rejects loopback, multicast, link-local and
unspecified destinations, the tunnel's own addresses, and — belt and braces —
the proxy's own addresses. A refused SYN gets a RST so the app fails fast instead
of hanging.

---

## DNS inside the tunnel

Covered in full in [`DNS-AND-IP.md`](DNS-AND-IP.md). In one paragraph: the tunnel
advertises its own resolvers to iOS, intercepts every UDP packet to port 53, and
re-issues the query through the proxy — over the SOCKS5 UDP association when
there is one, or as DNS-over-TCP inside a proxied stream when there is not. The
DNS message itself is never parsed; it is forwarded as opaque bytes and the
answer returned verbatim. No query reaches the resolver the physical network
handed the device.

---

## Credential delivery

Three paths, chosen at runtime, with the choice reported on the Diagnostics
screen:

| Path | Requires | Trade-off |
|---|---|---|
| App Group shared container | `com.apple.security.application-groups` on **both** bundles | Best: the password never enters the system VPN preferences |
| Inline in `providerConfiguration` | Nothing | iOS persists it in the system VPN preferences, outside the app sandbox |
| No credential | — | Only when the proxy needs no authentication |

The app checks the **extension's** provisioning profile for the App Groups
entitlement before choosing, because a partial strip — app keeps it, extension
loses it — would produce a tunnel that starts and then fails to authenticate with
no explanation. If in doubt, it takes the path that works and says so.

The `ProxyProfile` model has no password property at all, only a
`passwordReference` into the Keychain. There is no field that *could* hold a
secret, so "passwords are not written to disk in plain text" is a structural
property rather than a discipline.

---

## Privacy and security properties

**Guaranteed by construction:**

* no password in `UserDefaults`, in a plain file, in a log line, or in source;
* every log line passes through `LogRedactor` before being stored or handed to
  `os_log`;
* `ProxyCredential`, `ProxyProfile` and `TunnelConfiguration` all have redacted
  `description`s, so accidental interpolation cannot leak;
* the extension drops its credential from memory when the tunnel stops.

**Guaranteed by the design, not measured on a device:**

* DNS queries do not reach the physical network's resolver. The interception path
  is unit-tested; a live packet capture on an iPhone has not been performed.
* The tunnel's own transport does not loop back into the tunnel.

**Not claimed:**

* zero DNS leaks, in general. Encrypted DNS started by an app (DoH/DoT) is not
  intercepted — it is proxied like anything else, which is fine because it is
  already encrypted, but the tunnel cannot see it.
* anything resembling a firewall. The on-demand rule is iOS's own behaviour.
* that a proxy improves privacy. Your proxy operator sees every destination you
  connect to, and the contents of any plaintext protocol.

---

## Why a static local package instead of SPM dependencies

`Project.yml` declares zero external dependencies. Everything is Apple's own
frameworks: Foundation, Network, NetworkExtension, Security, SwiftUI.

The reasons are practical:

* the project must build on a GitHub-hosted runner with nothing installed but
  Xcode and XcodeGen;
* every dependency is another thing that can break a build you cannot debug
  locally;
* the interesting code here *is* the protocol implementation, and pulling in a
  third-party proxy library would defeat the purpose.

`ProxyTunnelCore` is a local package rather than a plain group of files because
it gives a clean module boundary — `@testable import ProxyTunnelCore` — and
because it can be compiled and reasoned about on its own.
