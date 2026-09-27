# DNS, IPv4 and IPv6

How name resolution and address families are handled inside the tunnel, and where
the limits are.

---

## The DNS leak problem

A packet tunnel that resolves names with the system resolver has not really
protected anything. The carrier, or the Wi-Fi network's operator, still sees
every name you look up — even while all your TCP traffic goes through a proxy.
Worse, iOS will happily keep using a resolver learned from the physical network
unless the tunnel explicitly replaces it.

## What this tunnel does

```
iOS app asks for "example.com"
        │  UDP :53  ─┐
        ▼            │
  routed into the tunnel
        │
┌───────▼─────────────────────────────────────────────────────────┐
│ TunnelEngine.handleUDP                                          │
│   destinationPort == 53  or  5353 ?                             │
│        │                                                        │
│        ▼                                                        │
│   DNSTunnelResolver                                             │
│     ├── SOCKS5 UDP association available?                       │
│     │     └─ forward the raw query over the relay, wait for the │
│     │        reply, verify the transaction ID, return it        │
│     │                                                           │
│     └── otherwise (HTTP CONNECT / HTTPS, or the relay failed)   │
│           └─ open a proxied stream to the resolver on port 53,  │
│              send [uint16 length][query], read the same framing│
│              back (RFC 7766 DNS-over-TCP)                       │
│                                                                 │
│   wrap the answer in a UDP packet, source = the resolver         │
│   the app targeted, destination = the app's socket               │
└─────────────────────────────────────────────────────────────────┘
```

Two properties matter:

1. **The resolver address the app targeted is the one used.** iOS is given a
   `NEDNSSettings` list; the tunnel uses whatever address the resulting packet
   was sent to. There is no "second resolver" anywhere, and
   `supplementalMatchDomains` is deliberately never set — that would create a
   bypass.
2. **The DNS message is never parsed.** The query is forwarded as opaque bytes
   and the answer returned verbatim. EDNS0, DNSSEC records, unknown RR types and
   future extensions all pass through untouched. This is also why the
   implementation is short enough to be obviously correct.

`matchDomains` is set to `[""]`, which makes the tunnel's resolvers the *default*
for every name rather than only for specific suffixes.

### Why DNS works with HTTP CONNECT at all

HTTP CONNECT cannot carry UDP. Rather than letting DNS fail (or, far worse,
letting it fall back to the physical network), the tunnel terminates UDP:53
locally and re-issues the query as DNS-over-TCP inside a proxied stream.

This is a real, standards-based mechanism (RFC 7766), it needs no UDP anywhere,
and it means DNS works identically across all three supported protocols.

### Rates and limits

* At most 24 DNS queries are in flight at once; beyond that, queries are dropped
  and counted rather than queued without bound.
* Queries larger than 8 KiB are refused.
* The DNS-over-TCP path opens one proxied connection per query. Correct, but not
  cheap. A connection pool would be faster and would be broken by iOS suspending
  the extension at arbitrary moments; the trade was made deliberately.
* Timeouts: 10 s over the UDP relay, 15 s over TCP.
* The UDP relay path verifies the DNS transaction ID before accepting a reply, so
  a stray datagram cannot be attributed to the wrong query.

### What is *not* intercepted

**Encrypted DNS started by an app** — DoH on 443, DoT on 853 — is not touched. It
is TCP (or QUIC) to a port, and it is proxied like anything else. That is fine:
it is already encrypted, and the tunnel has no business breaking it. But it does
mean this tunnel cannot claim to know what names an app resolved.

**mDNS / Bonjour** (UDP 5353) is intercepted by the same path, which is not
useful for local discovery and may break `.local` resolution inside the tunnel.
If you need local device discovery, that is a reason to exclude those routes.

### Honest statement about leaks

The design guarantees that a query sent to the advertised resolvers cannot reach
the physical network's resolver: those packets are captured by the default route
and answered in-process. That is verified by unit tests that drive the whole path
with a synthetic UDP:53 packet.

What has **not** been done is a live packet capture on a device with the tunnel
running, because that requires the Network Extension entitlement. So the claim is
"the design prevents it and the path is tested", not "measured zero leaks".

---

## IPv4

### Configuration

| Setting | Value |
|---|---|
| Tunnel address | `10.7.0.1` |
| Subnet mask | `255.255.255.0` |
| Included routes | `0.0.0.0/0` |
| Excluded routes | each resolved proxy address as `/32` |

`10.7.0.1` sits inside the `10/8` private range. The tunnel takes the default
route and therefore supersedes any home-router subnet, so a collision is not
harmful in practice.

### The excluded route is not optional

The extension's own connection to the proxy is a socket in the extension process.
Once the tunnel installs a default route, packets from that socket would be
routed *into the tunnel* — back to the extension — and the tunnel would never
come up.

The app resolves the proxy hostname **before** the tunnel exists, using the
physical network's DNS, and passes the address list in
`TunnelConfiguration.resolvedProxyAddresses`. The extension adds each address as
an excluded route and dials IP literals only.

`PhysicalInterfaceResolver` additionally pins the transport to the physical
interface via `NWParameters.requiredInterface`, as a second line of defence on a
multi-homed device.

---

## IPv6

### Configuration

| Setting | Value |
|---|---|
| Tunnel address | `fd00:7:7:7::1` |
| Prefix length | 64 |
| Included routes | `::/0` |
| Excluded routes | each resolved proxy address as `/128` |

`fd00::/8` is the RFC 4193 unique-local range, chosen so that nothing on the
public internet can ever route to the tunnel address directly.

### Why IPv6 is routed into the tunnel by default

Two reasons, and both are about not breaking things:

1. **IPv6-only carrier networks exist.** On such a network, a tunnel that does
   not carry IPv6 carries nothing at all.
2. **Not routing it is a leak, not a block.** If IPv6 is left outside the tunnel,
   iOS keeps using it for anything that prefers it — which on a dual-stack
   network is most things — and that traffic bypasses the proxy entirely while
   still working. From the user's point of view the app looks connected and half
   the traffic is not proxied.

Apple's App Store review guidelines (§2.5.15 / the IPv6 requirement) also
effectively require IPv6 support for network apps.

### What can go wrong

**An IPv4-only proxy cannot reach IPv6 destinations.** This is the common case:
most commercial proxy endpoints are IPv4-only. An app connecting to an IPv6
literal will get a refusal from the proxy, reported as
`proxyRefusedConnection` with `network unreachable` or `host unreachable`.

The tunnel logs a one-time diagnostic note when this happens, suggesting you
disable IPv6 — which is a genuine trade, not a fix:

> Turning IPv6 off does not "block" it — IPv6 traffic simply leaves the tunnel and
> uses your normal connection, which is a leak. Only turn it off if your proxy
> provider cannot handle IPv6 destinations.

The Connect screen shows a persistent warning banner whenever IPv6 routing is
disabled, so the state is never silent.

### DNS64 / NAT64

Some carriers run IPv6-only networks and synthesise IPv6 addresses for IPv4-only
destinations using DNS64, with NAT64 to translate. How that interacts with this
tunnel:

* DNS64 happens at the resolver. Because this tunnel forwards queries to the
  resolver **you configured** (typically a public resolver that does *not* do
  DNS64), you will generally get plain A records rather than synthesised AAAA
  records. That is usually what you want through a proxy, because the proxy can
  reach the real IPv4 address.
* If the proxy itself is only reachable over IPv4 while the phone is on an
  IPv6-only network, the proxy connection fails at the transport level, before
  anything else. That is reported as `proxyUnreachable` with the underlying
  POSIX error.
* If the proxy is IPv6-reachable and the destination is IPv6-only, everything
  works normally.

There is no special handling for 464XLAT or CLAT interfaces; the tunnel sees
ordinary IPv6 packets either way.

---

## Address-family summary

| Network | Proxy family | Result |
|---|---|---|
| Dual-stack | IPv4 or IPv6 | ✅ works; IPv6 destinations need an IPv6-capable proxy |
| IPv4-only (most Wi-Fi) | IPv4 | ✅ works |
| IPv4-only | IPv6-only proxy | ❌ proxy unreachable at the transport level |
| IPv6-only carrier | IPv4 proxy | ❌ unless the proxy also has an IPv6 address |
| IPv6-only carrier | IPv6 proxy, IPv4 destinations | ✅ works — the proxy does the IPv4 leg |
| DNS64/NAT64 | IPv6 proxy | ✅ synthesised addresses are proxyable if the proxy can reach them |

The app resolves AAAA records as well as A records and passes both to the
extension, so an IPv6-capable proxy is used over IPv6 without any configuration.

---

## Testing coverage

The engine tests in `Tests/ProxyTunnelCoreTests/TunnelEngineTests.swift` cover:

* `0.0.0.0/0` and `::/0` installed as included routes;
* proxy addresses installed as `/32` and `/128` exclusions;
* IPv6 settings absent, and a warning present, when IPv6 is disabled;
* a DNS query fed in as a synthetic UDP:53 packet, carried as DNS-over-TCP
  through a real local proxy, and returned as a UDP packet to the right client
  port with the payload intact.

What is **not** tested, and cannot be without a device and an entitlement: real
DNS behaviour under iOS, real routing on a live network, and real NAT64.
