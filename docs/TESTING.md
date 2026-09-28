# Testing

What is tested, what is not, and why the difference matters.

---

## Where the suite stands

Two batches run in CI on an iOS Simulator, and the split is deliberate: it means a
slow or stuck batch cannot hide the other's result.

| Batch | Contents | Status in CI |
|---|---|---|
| **Logic** | Validation, models, codecs, profile and settings storage, Keychain error mapping | 147 tests, all passing |
| **Integration** | TCP state machine, tunnel engine, live SOCKS5 and HTTP CONNECT proxies, Keychain | 61 passing, **7 skipped** (see below) |

**The 7 skipped tests are the Keychain round-trip tests.** iOS derives an app's
default keychain access group from its code signature (team identifier + bundle
identifier). A host-less unit-test bundle on the Simulator has no such identity,
so `SecItemAdd` returns `errSecMissingEntitlement` (-34018). That is a property of
the test *process*, not of `KeychainSecretStore`, so those tests call `XCTSkip`
with the reason rather than reporting a failure they cannot justify. They run on a
device build, or from Xcode against a signed test host.

Nothing else is skipped. In particular the live-proxy tests **do** run: a real
SOCKS5 server and a real HTTP CONNECT server are started on loopback inside the
test process, and the production client is driven against them.

---

## Running the tests

**In CI:** every push and every manual dispatch runs both batches. Results are in
the `ProxyTunnel-iOS-build-logs` artifact (`tests-logic.txt`,
`tests-integration.txt`, and the two `.xcresult` bundles).

**Locally, on a Mac:**

```bash
xcodegen generate
xcodebuild test \
  -project ProxyTunnel.xcodeproj \
  -scheme ProxyTunnelCoreTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

There is no `swift test` path. `ProxyTunnelCore` imports NetworkExtension,
Security and Network, and the Keychain tests only mean something on an iOS
simulator — see [What the tests cannot do](#what-the-tests-cannot-do).

---

## What the suite covers

### Validation — `ValidationTests.swift`

| Area | Cases |
|---|---|
| Host | IPv4 literal; IPv6 with and without brackets; hostname with case normalisation; empty; embedded credentials (`user:pass@host`); URL scheme prefixes; paths and query strings; a port inside the host field; malformed IPv4 (`999.999.999.999`); hyphens at label boundaries; spaces; loopback and link-local warnings; single-label names; **zero-width and bidi control characters**; over-long names and labels |
| Port | valid range; whitespace trimming; empty; non-numeric; zero; 65536; privileged-port warning; protocol/port mismatch warnings |
| Whole profile | a complete draft; no-authentication profiles; password without username (error); username without password (warning); name derivation; over-long usernames and passwords (error for SOCKS5, warning for HTTP); notes that look like they contain a secret; **all problems reported at once**; mock profiles flagged |
| DNS settings | IPv4 acceptance and de-duplication; hostnames rejected; empty-list warning; comma/newline/space splitting; multicast rejected |

The zero-width-character case is worth calling out: a host containing U+200B
renders identically to a clean one while resolving somewhere else. The sanitizer
strips it, and the test pins that behaviour.

### Models — `ModelTests.swift`

| Area | Cases |
|---|---|
| Profile coding | round-trip; `protocol` key name in JSON; **no password-shaped field in the encoded output**; decoding a document written by an older build; IPv6 bracketing; redacted summaries and `description` |
| `TunnelConfiguration` | round-trip through `providerConfiguration`; **the dictionary is plist-serialisable**; schema-version rejection; missing payload; redaction; credential construction rules |
| Connection state | disconnected, failed, connected, reasserting; session start propagation; busy flags; **mock state never reports connected** |
| Redaction | URL user-info; `password=`/`token=`/`api_key=` forms; `Proxy-Authorization`; long base64 blobs; ordinary text left alone; `ProxyCredential`/`ProxyProfile`/`TunnelFailure` descriptions |
| Protocol capabilities | every protocol has a full description; a protocol advertising no UDP support does not describe UDP as supported |

That last one is a real guard rather than a formality: every claim the UI makes
about a protocol is read from `ProxyProtocolCapabilities.describe(_:)`, and this
test stops the documentation drifting away from the implementation.

### Codecs — `CodecTests.swift`

Byte-for-byte, with no sockets:

* **Internet checksum** against the RFC 1071 worked example; odd-length padding;
  the "checksummed block sums to 0xFFFF" property.
* **IPv4** header checksum validity after building; round-trip; fragmented packets
  rejected; truncated header rejected; unknown version rejected.
* **IPv6** round-trip; **hop-by-hop extension header walking**; fragment header
  rejected.
* **TCP** header round-trip; the flag byte layout pinned against the standard
  values; checksum verified by re-summing the finished segment; option padding to
  a 4-byte boundary; data-offset calculation; sequence arithmetic around SYN and
  FIN; MSS and window-scale option parsing; a bad data offset rejected.
* **UDP** round-trip; the IPv6 checksum is present and non-zero.
* **SOCKS5** greeting layout; method selection including `0xFF`; incomplete
  messages reporting how many bytes are still needed; the RFC 1929 request layout;
  over-long credential fields rejected; CONNECT requests for IPv4, IPv6 and
  domain names; `UDP ASSOCIATE`; reply parsing for every reply code; domain-name
  bound addresses; UDP datagram framing.
* **HTTP CONNECT** request layout for IPv4, IPv6 and hostnames; pre-emptive Basic
  credentials; `200`, `407` and bare-LF responses; incomplete heads; non-HTTP
  responses; **the exact byte offset of the head terminator**, so leftover body
  bytes survive; header-injection attempts rejected.

### Storage — `StorageTests.swift`

* **Real Keychain** via the `Security` framework on the simulator: store, read
  back, overwrite without duplicating, missing item returns `nil` rather than
  throwing, idempotent delete, key enumeration, non-ASCII and long secrets.
* The default store uses **no explicit access group** — asserted, because an
  explicit group needs an entitlement a free-Apple-ID build does not have.
* `ProfileStore`: metadata and secret stored separately; the password absent from
  the JSON document; first profile auto-selected; update keeping / replacing /
  removing a password; delete removing the Keychain item; persistence across
  instances; **a corrupt file is kept rather than deleted**; detecting a missing
  Keychain item (what a device restore looks like); credential construction;
  enable/disable.
* `AppSettings`: defaults, round-trip, fallback on a missing file, IPv6-off
  reported as a leak.

### TCP state machine — `TCPConnectionTests.swift`

Driven deterministically by a scripted packet sink and a fake proxy stream, so
timing-sensitive cases are reproducible rather than hopeful:

* SYN produces a SYN-ACK with the negotiated MSS and window scale, addressed
  correctly and acknowledging the SYN.
* A proxy stream is opened to the right destination; a **retransmitted SYN does
  not open a second one** and reuses the same ISN.
* Client data reaches the proxy; duplicates are acknowledged but forwarded once;
  **out-of-order data is buffered and delivered in order**.
* Data arriving before the proxy stream is ready is buffered and flushed.
* Proxy data becomes correctly sequenced TCP packets.
* **Unacknowledged data is retransmitted**; the connection gives up after the
  retry limit and reports a timeout.
* Acknowledging clears outstanding bytes and stops retransmission.
* A zero window stops sending.
* Proxy EOF produces a FIN *after* queued data; a client FIN is acknowledged; RST
  closes immediately; **a proxy failure produces a RST so the app fails fast**
  rather than hanging.
* Idle timeout.
* Sequence-number wraparound arithmetic across the 2³² boundary.

### End-to-end proxying — `ProxyIntegrationTests.swift` and `TunnelEngineTests.swift`

These are the tests that matter most, because they use **real sockets**.

`LocalProxyServer.swift` implements, on `NWListener`:

* a SOCKS5 server that really performs the handshake, really checks RFC 1929
  credentials, and really connects to the requested target and relays bytes;
* an HTTP CONNECT server that really parses the request head, really validates
  `Proxy-Authorization`, and really relays;
* an echo server that stands in for the origin;
* knobs for the failure cases: force a reply code, offer only GSSAPI, require
  credentials, inject a redirect, return a fixed body, answer with garbage.

Against those, the suite covers:

| Test | What it proves |
|---|---|
| SOCKS5 relay | bytes round-trip through a real SOCKS5 proxy |
| SOCKS5 with RFC 1929 | credentials are framed and accepted correctly |
| Wrong password | reported as `authenticationRejected`, and the server recorded the failure |
| No credentials against an authenticating proxy | reported as `authenticationRequired` |
| Proxy refuses the target | reported as `proxyRefusedConnection` with the server's own reason |
| GSSAPI-only server | reported as `unsupportedAuthMethod`, not a hang |
| HTTP CONNECT relay | bytes round-trip through a real HTTP proxy |
| HTTP CONNECT credentials | the exact `Proxy-Authorization: Basic …` header the server received |
| HTTP 407 | `authenticationRequired` / `authenticationRejected` |
| HTTP 502 | `proxyRefusedConnection` carrying the proxy's status line |
| Connection refused | reported as such, not hung |
| Wrong-protocol server | a clear protocol-mismatch error, both directions |
| `UDP ASSOCIATE` against an HTTP proxy | refused **without touching the network** |
| Probe egress IP | `ProxyProbe` returns the IP the origin served |
| Probe failure | no egress IP is invented when the probe fails |
| Host resolution | literals pass through; `localhost` resolves **with IPv4 first**; invalid names fail cleanly |

And through the full `TunnelEngine`, with a scripted virtual interface:

| Test | What it proves |
|---|---|
| SYN → SYN-ACK | the engine dispatches packets, creates a flow, dials a real proxy |
| **Full round trip** | payload in → real SOCKS5 → real target → echo → back out as TCP packets |
| Loopback destination | refused with a RST and counted |
| The proxy's own address | refused, so a stale route cannot create an infinite loop |
| Unsolicited data | RST, not a silent drop |
| Fragmented packet | dropped and counted, nothing written back |
| Malformed packet | dropped and counted |
| ICMP | counted as unsupported rather than ignored |
| UDP with relaying off | dropped and counted |
| **DNS over TCP through the proxy** | a synthetic UDP:53 packet is carried as DNS-over-TCP through a real proxy and returned as a UDP packet to the right port, with the payload intact |
| Statistics | counters reflect what actually happened |
| Status payload | contains no credential material, verified by encoding it to JSON and searching |
| Connection limit | the third SYN past a limit of two is rejected and counted |
| Network settings | `0.0.0.0/0` and `::/0` included, the proxy excluded as `/32` and `/128`, DNS match domains set, MTU set, IPv6 omitted with a warning when disabled |

---

## What the tests cannot do

Being explicit about this is the point.

### They cannot prove the tunnel starts on a device

Everything above runs on the iOS **Simulator**, which does not enforce Network
Extension entitlements. A simulator will happily let a `NEPacketTunnelProvider`
start with no entitlement at all. So a fully green run says nothing about whether
iOS will accept the tunnel on your iPhone — and as
[`ENTITLEMENTS-AND-SIGNING.md`](ENTITLEMENTS-AND-SIGNING.md) explains, with a free
Apple ID it will not.

The tunnel's *logic* is tested end to end. The tunnel's *admission* is not
testable here, and cannot be.

### They cannot validate against a real proxy provider

Every test uses a proxy implemented in the test process on loopback. That is
deliberate — a test that depends on a third party's uptime and credentials is not
a test — but it means the suite proves conformance to the RFCs, not interoperation
with any specific provider. ProxyCheap, or whoever you use, may do something
non-standard; only the app's **Test connection** button, run against the real
endpoint, will tell you.

### They do not measure performance

No throughput, latency or battery assertions. The userspace TCP stack has no
congestion control and no SACK, and a synthetic loopback test would flatter it.

### They do not test on a real radio

Wi-Fi ↔ cellular handover, IPv6-only carriers, NAT64/DNS64, captive portals and
lossy links are all out of reach. `PhysicalInterfaceResolver` handles interface
selection, but its behaviour under a real handover is untested.

### They do not test the VPN permission flow

`NETunnelProviderManager.saveToPreferences` and the user consent alert need a real
device and an entitled build.

---

## Deliberate gaps

Cases that are known to be uncovered, listed so they are not mistaken for
oversights:

| Gap | Why |
|---|---|
| `KeychainSecretStore` round trips | **Skipped in CI.** A host-less test bundle on the Simulator has no keychain access group (`errSecMissingEntitlement`, -34018). Runs on a device, or from Xcode against a signed test host |
| `DNSTunnelResolver` over a real SOCKS5 UDP association | The test SOCKS5 server does not implement `UDP ASSOCIATE`. The DNS-over-TCP path *is* covered end to end, and the UDP relay's framing is covered at the codec level |
| `SOCKS5UDPRelay` data path | Same reason. The class is exercised indirectly (the engine tries to establish a relay and falls back cleanly) but a full datagram round trip is not covered |
| TLS (`HTTPS CONNECT`) against a real TLS proxy | Would need a certificate the test trusts. The TLS *configuration* (SNI, minimum version, no pinning) is asserted by reading the code path, not by handshaking |
| `EntitlementInspector` against a real `.mobileprovision` | Needs a signed bundle. The plist extraction is a pure function and is straightforward, but there is no fixture |
| The SwiftUI layer | No snapshot or UI tests. Views are thin; the logic they call is tested |
| `TunnelController` against `NETunnelProviderManager` | Needs a device and an entitlement |
| Everything in `PhysicalInterfaceResolver` | Needs a real network path |
| IPv6 in the tunnel engine | The engine tests use IPv4 packets. The IPv6 code paths (header parse/build, extension-header walking, checksums) are covered at the codec level |

---

## Bugs this suite found

Recorded because it is the argument for byte-level tests existing at all. Every
one of these was found here and fixed.

| Bug | How it surfaced |
|---|---|
| **`ProxySession.Runner` and the DNS `LengthPrefixedReader` were deallocated mid-handshake.** Every stream callback captured `self` weakly so a stalled peer could not leak them — and nothing else retained them either, so `ProxySession.run()` returned and the object died with the greeting already sent. Every later completion found `self == nil`. **On a device this would have made every proxied connection hang until TCP gave up: the tunnel would have started, installed its routes, and carried nothing** | Every live-proxy test failed with "the connector never completed", and with no handshake timeout either — the timer belonged to the dead object, so only the connector's outer watchdog ever fired |
| **`TCPSegment.serialized()` never reserved the two-byte checksum field**, so the header was 18 bytes instead of 20: every option and payload byte was shifted by two, and the checksum was written over the urgent pointer. `parse()` then skipped the checksum, so the two errors cancelled out in a simple round trip | `testRoundTripsAHeader` got `"llo"` instead of `"hello"`; the engine tests then failed en masse with `truncated: needed 28, have 26` |
| **`SOCKS5.request()` appended the `ATYP` byte a second time**, inserting a stray byte and shifting the port by one. Every SOCKS5 `CONNECT` the client sent was malformed | `testConnectRequestWithIPv4` expected 10 bytes and got 11 |
| `LogRedactor`'s Authorization rule ran *after* the generic key/value rule, which consumed only the scheme word and left the credential in place | `testMasksProxyAuthorizationHeader` found the base64 blob still present |
| The test SOCKS5 server's per-connection session was a local, so it accepted connections and never replied | The SOCKS5 integration tests could never have passed |

---

## Adding tests

The patterns worth reusing:

**Protocol codecs get exhaustive unit tests, not integration tests.** `SOCKS5` and
`HTTPConnect` are pure functions over `Data`. Every boundary — incomplete
messages, wrong versions, over-long fields, malformed replies — is cheap to test
there and expensive to reach through a socket.

**The TCP state machine is driven, not waited on.** `ScriptedPacketFlow` lets a
test decide exactly when packets arrive and `FakeProxyOpener` decides exactly when
the proxy "connects" and what it sends back. No sleeps, no flakiness.

**New protocols get a real loopback server.** `LocalProxyServer.swift` is the
template: implement enough of the server side to do a genuine handshake and a
genuine relay, then test the client against it. A codec test alone would not have
caught, for example, that the server sends its reply in two TCP segments.

**Assert the negative.** Several tests exist to pin down what must *not* happen:
no egress IP invented on failure, no credential in a status payload, no connected
state reported in mock mode, no second proxy stream on a retransmitted SYN. Those
are the properties that fail silently in production.
