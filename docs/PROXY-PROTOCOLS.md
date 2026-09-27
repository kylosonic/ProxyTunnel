# Proxy protocols: what each one can and cannot carry

This document describes what the implementations in
`Packages/ProxyTunnelCore/Sources/ProxyTunnelCore/Proxy/` actually do. Where a
protocol cannot carry something, it says so rather than leaving you to discover
it.

## The capability matrix

| | **SOCKS5** | **HTTP CONNECT** | **HTTPS CONNECT** |
|---|---|---|---|
| Specification | RFC 1928, RFC 1929 | RFC 9110 §9.3.6 | HTTP CONNECT inside TLS |
| **TCP** | ✅ full stream tunnelling | ✅ full stream tunnelling | ✅ full stream tunnelling |
| **UDP** | ✅ via `UDP ASSOCIATE` | ❌ **impossible** | ❌ **impossible** |
| **DNS** | ✅ over the UDP relay | ✅ via DNS-over-TCP in the tunnel | ✅ via DNS-over-TCP in the tunnel |
| **IPv4 destinations** | ✅ `ATYP=1` | ✅ dotted-quad authority | ✅ dotted-quad authority |
| **IPv6 destinations** | ✅ `ATYP=4` | ✅ `[v6]:port` authority | ✅ `[v6]:port` authority |
| **Remote name resolution** | ✅ `ATYP=3` | ✅ hostname authority | ✅ hostname authority |
| **Username/password auth** | ✅ RFC 1929 | ✅ Basic (pre-emptive) | ✅ Basic (pre-emptive) |
| **Transport encryption** | ❌ none | ❌ none | ✅ TLS to the proxy |
| **Certificate validation** | n/a | n/a | ✅ system trust store, SNI = proxy host |

**Recommendation: use SOCKS5.** It is the only one of the three that can carry
datagrams, which is what makes QUIC, HTTP/3, some games, some VoIP and some VPN
protocols work at all.

---

## SOCKS5

### What it does well

* **Everything TCP.** A single `CONNECT` command opens a byte pipe to any
  `host:port`, including by name, so the *proxy* resolves the name and the local
  resolver is never consulted.
* **UDP, properly.** `UDP ASSOCIATE` gives the client a relay endpoint on a
  separate UDP socket. Datagrams are sent with a small header describing their
  destination, and replies come back with a header describing their origin. That
  is a real NAT-like relay and it is what this tunnel uses for non-DNS UDP.
* **No protocol-specific baggage.** Nothing is rewritten, nothing is injected,
  nothing is logged by the proxy by default. It is a byte pipe.

### Limitations, stated plainly

* **No confidentiality of its own.** SOCKS5 does not encrypt anything.
  Credentials travel in a near-plaintext form (RFC 1929 does not even hash them)
  and so does your payload. On an untrusted network, everything between your
  phone and the proxy is readable.
* **UDP fragmentation is optional and usually absent.** `FRAG != 0` is defined by
  RFC 1928 and almost never implemented by servers. This client **drops**
  fragmented datagrams rather than pretending to handle them.
* **Half-close does not exist.** There is no way to say "I am done writing" short
  of closing the stream. See the tunnel's 120-second grace period in
  [`ARCHITECTURE.md`](ARCHITECTURE.md).
* **The relay must be reachable.** Some providers run the TCP listener on one
  host and the UDP relay on another, and some firewall the relay. If the
  association fails, the tunnel logs it and falls back to dropping non-DNS UDP —
  DNS still works, because it uses DNS-over-TCP in that case.
* **IPv6 depends on the proxy.** A SOCKS5 server on an IPv4-only host generally
  cannot reach IPv6 destinations. The failure shows up as
  `proxyRefusedConnection` with `network unreachable` or `host unreachable`.

### The exchange this client performs

```
client ──► VER=5, NMETHODS, METHODS...             (offer userPassword, none)
server ──► VER=5, METHOD                           (0x02 or 0x00)
   if 0x02:
client ──► VER=1, ULEN, UNAME, PLEN, PASSWD        (RFC 1929)
server ──► VER=1, STATUS                           (0x00 = accepted)
client ──► VER=5, CMD=CONNECT, RSV, ATYP, ADDR, PORT
server ──► VER=5, REP, RSV, ATYP, BND.ADDR, BND.PORT
           ────── now an opaque byte pipe ──────
```

For UDP, `CMD=UDP ASSOCIATE` replaces `CONNECT`, and the reply's `BND.ADDR` /
`BND.PORT` is the relay endpoint. The **TCP control connection must stay open**
for the whole lifetime of the association; this client holds it and reports
failure when it drops, because a silently dead relay is worse than a reported
one.

Many servers answer `UDP ASSOCIATE` with `0.0.0.0:0`, meaning "use the address
you are already talking to me on". This client handles that.

---

## HTTP CONNECT

### What it does well

* **Ubiquitous.** Every corporate proxy, every CDN, most hosting providers.
* **Simple.** `CONNECT host:port HTTP/1.1` and then it is a byte pipe.
* **Name resolution by the proxy**, because the request line carries a hostname.

### Limitations, stated plainly

* **No UDP. At all.** There is no datagram mechanism in the protocol. This is not
  a gap in this implementation; it does not exist. Consequences:
  * QUIC / HTTP-3 does not work. Modern browsers and many apps prefer it, and
    they will fall back to TCP-over-TLS when it fails — usually. When they do not,
    the connection simply fails.
  * UDP-based games, some VoIP, mDNS and most VPN protocols do not work.
  * Non-DNS UDP is **dropped** by the tunnel, and counted in the statistics so
    you can see it happening.
* **DNS needs a workaround, and this tunnel has one.** Because UDP is impossible,
  UDP:53 is terminated *inside* the tunnel and the query is re-issued as
  DNS-over-TCP (RFC 7766) inside a proxied stream. So DNS still resolves, still
  goes through the proxy, and still does not leak.
* **Credentials are HTTP Basic**, base64 of `user:password`, inside a plaintext
  request if the proxy connection is plaintext. They are sent **pre-emptively**
  rather than waiting for a 407, which saves a round trip and avoids the failure
  mode where a proxy closes the connection instead of challenging it.
* **Some proxies rewrite or block things** — they may inject their own error
  pages for failures, or block port 25, or refuse `CONNECT` to port 80. Those
  show up as `proxyRefusedConnection` with the proxy's status line.
* **IPv6 depends on the proxy**, as with SOCKS5.

### The exchange this client performs

```
client ──► CONNECT host:port HTTP/1.1
           Host: host:port
           User-Agent: ProxyTunnel/1.0 (iOS)
           Proxy-Connection: Keep-Alive
           Proxy-Authorization: Basic <base64>     (only when credentials exist)
           <blank line>
server ──► HTTP/1.1 200 Connection established
           <blank line>
           ────── now an opaque byte pipe ──────
```

Response parsing accepts `\r\n\r\n` and tolerates bare `\n\n`. A `407` maps to
"credentials required" (when none were sent) or "credentials rejected" (when they
were). Any other non-2xx becomes `proxyRefusedConnection` carrying the proxy's
own status line, so the message you see is the one the proxy sent.

The response head is capped at 32 KiB; anything larger is treated as a broken or
hostile proxy rather than buffered indefinitely.

---

## HTTPS CONNECT

### What it is

A normal HTTP CONNECT exchange, but the TCP connection to the proxy is first
wrapped in TLS. The proxy hostname is used as the SNI and as the certificate
verification name, and the certificate is validated against the iOS system trust
store.

### What it is not

**It is not an HTTP proxy that happens to listen on port 443.** Many providers
advertise "HTTPS proxy" meaning exactly that — a plaintext HTTP proxy on port
443 — and a TLS handshake against it will fail with
`tlsFailed` / `errSSLProtocol`.

If you see that error, the fix is to change the protocol in the app to
**HTTP CONNECT** and keep the same host and port, or to check whether your
provider documents a genuinely TLS-wrapped endpoint.

### Limitations

* Everything HTTP CONNECT cannot do, it cannot do — no UDP.
* TLS handshake and certificate validation add latency at connect time.
* The proxy terminates TLS and can therefore see your CONNECT requests in
  plaintext. If the proxy is hostile, TLS to it does not help; it only protects
  the hop between you and the proxy.
* IPv6 depends on the proxy.

### Why connect to a resolved IP with an explicit SNI

Inside the tunnel the extension must not perform DNS lookups — the tunnel is the
DNS path, so that would be circular. The app therefore resolves the proxy
hostname *before* the tunnel starts and passes IP addresses to the extension.

That means the TLS client is connecting to an IP literal, so
`NWByteStream` sets the SNI explicitly:

```swift
sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)
```

Without it, Network.framework would use the IP address as the verification name
and the certificate would not match.

Minimum TLS version is 1.2. No pinning, no custom trust evaluation, no way to
disable validation — deliberately.

---

## Choosing a protocol

| If you need | Use |
|---|---|
| Browsing, most apps, DNS | Anything |
| QUIC / HTTP-3, games, VoIP, WireGuard-over-proxy | **SOCKS5** |
| To traverse a corporate proxy you do not control | HTTP CONNECT |
| An untrusted network and your provider offers a TLS endpoint | **HTTPS CONNECT** |
| Username/password authentication over a hostile path | **HTTPS CONNECT** (SOCKS5 credentials are effectively plaintext) |

If your proxy provider offers all three on the same host, use **SOCKS5** for the
UDP support, and switch to **HTTPS CONNECT** when you are on a network you do not
trust — accepting that UDP-dependent apps will stop working.

---

## Adding a protocol

The proxy layer is deliberately structured so a new protocol is a small,
self-contained addition:

1. **A codec** — a pure, synchronous type that converts between `Data` and
   values, with no I/O. `SOCKS5` and `HTTPConnect` are the two existing examples.
   Codecs are where all the byte-level test coverage lives.

2. **A destination shape** — extend `ProxyDestination` if the protocol has a
   command vocabulary of its own.

3. **A handshake branch** — add a `case` to `ProxyProtocol` and a branch in
   `ProxySession.Runner.start()` and `Runner.advance()`. The runner is already a
   small state machine driven by a pull-based stream; a new protocol adds states
   to it rather than restructuring it.

4. **A capability description** — add a branch to
   `ProxyProtocolCapabilities.describe(_:)`. **This is not optional.** Every claim
   the UI makes about a protocol is read from there, and the test suite asserts
   that a protocol advertising no UDP support does not describe UDP as supported.

5. **Codec tests and an integration test** — the local test proxy servers in
   `Tests/ProxyTunnelCoreTests/TestSupport/LocalProxyServer.swift` are the
   pattern: implement enough of the server side to do a real handshake and a real
   relay on loopback.

Protocols worth adding, roughly in order of how much they would buy you:

* **Shadowsocks / VMess / Trojan** — encrypted proxy protocols, which would fix
  SOCKS5's biggest weakness without needing an HTTPS proxy endpoint.
* **HTTP/2 CONNECT** — some CDNs only offer proxying over HTTP/2.
* **Shadowsocks UDP** for a proper UDP path with encryption.

None of them change the tunnel: everything above `ProxyConnector` is protocol
agnostic.
