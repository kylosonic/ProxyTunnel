# Entitlements, code signing, and what actually works

This is the document that decides whether the rest of the project is useful to
you. It answers one question:

> Can an app built this way, installed this way, actually run a VPN-style proxy
> tunnel on an iPhone?

**No — not with a free Apple ID.** This document explains precisely why, with
sources, and what each signing route does and does not give you.

Two things it is not: it is not a way around Apple's entitlement system, and it
is not a reason the rest of the project is wasted. The app genuinely works, and
the parts that work are listed at the end.

---

## 1. The entitlement that matters

A Packet Tunnel Provider needs exactly one entitlement:

```xml
<key>com.apple.developer.networking.networkextension</key>
<array>
    <string>packet-tunnel-provider</string>
</array>
```

* **Key:** `com.apple.developer.networking.networkextension` ("Network Extensions
  Entitlement")
* **Type:** array of strings
* **Required value:** `packet-tunnel-provider`
* **Declared on:** the extension target — and, in practice, the host app too.
  Apple's App Store validation rejects an upload where either bundle is missing
  it, and shipping Network Extension apps (WireGuard's, for instance) carry it on
  both. This project declares it on both: see
  [`Config/ProxyTunnelExtension.entitlements`](../Config/ProxyTunnelExtension.entitlements)
  and [`Config/ProxyTunnel.entitlements`](../Config/ProxyTunnel.entitlements).

It is the sole "Essentials" entry in Apple's Packet Tunnel Provider
documentation, and it corresponds to the **Network Extensions** capability in
Xcode.

### What is *not* needed

`com.apple.developer.networking.vpn.api` with the value `allow-vpn` — the
**Personal VPN** capability — is *not* required for a packet tunnel. It scopes
the legacy `NEVPNManager` API and built-in IPsec/IKEv2. Advice from 2016–2017
saying "you need both" is stale. This project does not request it.

---

## 2. Free Apple ID: the hard stop

Apple publishes a capability table at
<https://developer.apple.com/help/account/reference/supported-capabilities-ios/>
with three columns: **ADP** (Apple Developer Program), **ADEP** (Enterprise), and
**Apple Developer** — the last of which is the free, zero-cost tier.

The relevant rows:

| Capability | ADP | ADEP | Free ("Apple Developer") |
|---|---|---|---|
| Network extensions | ✓ | ✓ | **—** |
| Personal VPN | ✓ | ✓ | **—** |
| App groups | ✓ | ✓ | ✓ |
| Keychain sharing | ✓ | ✓ | ✓ |
| Background modes | ✓ | ✓ | ✓ |
| Data protection | ✓ | ✓ | ✓ |
| HealthKit | ✓ | ✓ | ✓ |
| HomeKit | ✓ | ✓ | ✓ |
| Maps | ✓ | ✓ | ✓ |
| Inter-App Audio | ✓ | ✓ | ✓ |
| Wireless Accessory Configuration | ✓ | ✓ | ✓ |
| Push notifications | ✓ | ✓ | **—** |
| iCloud (all services) | ✓ | ✓ | **—** |
| Associated domains | ✓ | ✓ | **—** |
| Sign in with Apple | ✓ | ✓ | **—** |
| App Attest | ✓ | ✓ | **—** |

**Network Extensions is not available to free accounts.** Neither is Personal
VPN. That is the blocker, and it is a licensing restriction, not a technical one.

The check marks in that table are rendered as icons and are invisible to text
extraction, which is why so many secondary sources hedge about App Groups. The
table above was read directly from the page's DOM — see
[`research/apple-entitlement-research-report.md`](research/apple-entitlement-research-report.md)
for the transcription and the method.

### Xcode says so plainly

Attempting to add the Network Extensions capability with a Personal Team
produces:

> Personal development teams, including "My Name" do not support Network
> Extensions Capability

And Apple DTS (Matt Eaton) answered a developer hitting exactly this on the Apple
Developer Forums (thread 675195):

> Not without code signing with the Network Extension capability tied to your
> Developer Account.

### And the build-time failure is where it stops

Because a Personal Team cannot provision the capability at all, the failure
happens at **signing time**, before the app is ever installed. There is no
free-team report anywhere of a packet tunnel reaching runtime, because it cannot
get that far. That is worth stating precisely: the common belief "it installs but
the VPN silently doesn't work" is describing a *different* situation — a build
signed with a paid certificate whose profile is missing the capability, or an
entitlement stripped after signing.

---

## 3. Paid account: what changes

A paid Apple Developer Program membership ($99/year) makes the Network Extensions
capability **self-service**. There is no request form and no approval process.

Apple DTS (Quinn "The Eskimo!"), Apple Developer Forums thread 67613:

> Originally, using any of these facilities required authorisation from Apple…
> **In Nov 2016 this policy changed for Network Extension providers. Any
> developer can now use the Network Extension provider capability like they would
> any other capability.**

Confirmed again in a 2026 thread (816877):

> **There is no approval process for this.** Most NE entitlements, including the
> one for content filters, are available to all (paid) developers.

Two Network Extension entitlements *do* still need Apple authorisation:
`NEAppPushProvider` and `NEHotspotHelper`. A packet tunnel provider is not one of
them.

Note also that the Developer Program License Agreement §3.3.3(G) still
contractually reserves Apple's right to withhold or revoke such entitlements.

**Practical summary:** pay $99/year, tick "Network Extensions" in Xcode, and the
tunnel works. Nothing in this project's source needs to change.

---

## 4. What happens at runtime without the entitlement

Two observed failure signatures, both reported by developers who had a tunnel
configured but not properly entitled:

```
Error Domain=NEVPNErrorDomain Code=5 "permission denied"
Error Domain=NEConfigurationErrorDomain Code=10 "permission denied"
```

`NEVPNErrorDomain` code 5 is `NEVPNErrorConfigurationReadWriteFailed` — see §6.
The message never mentions entitlements, which is *exactly* why this app inspects
its own provisioning profile and tells you the answer itself.

Other consequences, with honest confidence levels:

| Question | Answer | Confidence |
|---|---|---|
| Does the extension process launch? | No — iOS will not launch a `com.apple.networkextension.packet-tunnel` extension whose signature lacks the entitlement. Documented on macOS (`Found 0 registrations for … com.apple.networkextension.packet-tunnel`); inferred for iOS. | MEDIUM for iOS |
| What does `saveToPreferences` return? | `NEVPNErrorDomain Code=5 "permission denied"` | MEDIUM-HIGH (observed) |
| What does `loadAllFromPreferences` do? | Not documented; no reliable report found. **Unverified.** | UNVERIFIED |
| Does the "add VPN Configurations" alert appear? | Not documented in this case. **Unverified.** | UNVERIFIED |
| Does `startVPNTunnel()` throw? | Only reachable if saving succeeded, which it usually does not. | UNVERIFIED |

This project does not invent answers where the evidence runs out. What it does
instead is make the app tell you what it *can* determine for certain — see §5.

---

## 5. How this app detects and reports the situation

On launch, and whenever you open **Settings ▸ Diagnostics**, the app:

1. reads its own `embedded.mobileprovision` and that of every `.appex` inside
   `PlugIns/`. A provisioning profile is a CMS blob whose payload is an ordinary
   XML plist **in the clear**, so this needs no private API;
2. parses the `Entitlements` dictionary out of each one;
3. reports which keys survived signing, along with the team identifier, validity
   dates and provisioned device count;
4. states a verdict, and blocks the CONNECT button with an explanation when the
   entitlement is definitely absent.

It also reports whether the App Group container is actually available and which
credential-delivery path is in use.

`EntitlementInspector` is in
`Packages/ProxyTunnelCore/Sources/ProxyTunnelCore/Diagnostics/EntitlementInspector.swift`.

The verdict strings are deliberately blunt. When the entitlement is missing, the
Connect screen says:

> **This build cannot start a VPN tunnel** — The packet tunnel extension in this
> build does NOT have the `com.apple.developer.networking.networkextension`
> entitlement with the value `packet-tunnel-provider`. iOS will refuse to start
> it. The rest of the app (profile management, credential storage and the
> connectivity test) still works.

---

## 6. Error codes, for reference

From Apple's shipped `NEVPNManager.h` (the header, because Apple's web
documentation publishes the case names but not the numbers):

| Code | Name | Meaning here |
|---|---|---|
| 1 | `ConfigurationInvalid` | The configuration is not valid. On a sideloaded build, usually a mis-signed extension. |
| 2 | `ConfigurationDisabled` | iOS has the configuration marked disabled. |
| 3 | `ConnectionFailed` | The tunnel could not be brought up. |
| 4 | `ConfigurationStale` | The configuration changed between saving and starting. Reload and retry. |
| 5 | `ConfigurationReadWriteFailed` | **This is where the missing-entitlement failure surfaces**, as "permission denied". |
| 6 | `ConfigurationUnknown` | Unclassified. |

Codes 4 and 5 are commonly transposed in blog posts and forum answers. This app
maps them explicitly by number, with the table in a comment at the mapping site.

---

## 7. Sideloadly specifically

Sideloadly is closed-source and does not document its entitlement handling, so
this section separates what is documented from what is inferred.

### Documented behaviour

* **Free Apple ID support.** Sideloadly registers an App ID, obtains a
  certificate and fetches a 7-day provisioning profile through Apple's developer
  API.
* **App extensions are supported**, and removal is offered as a fallback:
  *"Remove Extensions — Remove individual or all app extensions (PlugIns) before
  install."*

  > ⚠️ **Do not enable this option for ProxyTunnel.** It deletes
  > `PlugIns/ProxyTunnelExtension.appex`, which is the entire tunnel. The app will
  > still install, and its Diagnostics screen will report that no PlugIns
  > directory exists.

* **Bundle identifiers may be rewritten.** Sideloadly's FAQ:
  *"Apple has prevented users on free Apple accounts from sideloading apps that
  have the same bundle ID as an App Store app. As a result, we are forced to set a
  unique bundle ID."*

  This project is written for that: `AppIdentifiers.tunnelProviderBundleIdentifier`
  reads the real identifier out of the embedded `.appex` at runtime instead of
  assuming `<app>.tunnel`. Assuming would point `NETunnelProviderProtocol` at a
  bundle identifier that does not exist, and `saveToPreferences` would fail with a
  generic error.

* **Custom entitlements are a paid feature.** Sideloadly 0.60.0 release notes:
  *"Added support for custom app entitlements (Apple Developer Program only)"* —
  and it is gated behind their Patreon tier.

* **Custom certificates are not supported.** The developer, in 2024:
  *"This is not currently supported but it's a feature we'd like to add."*
  There is no `.p12` / `.mobileprovision` equivalent of the Apple ID flow.

### Not documented — and therefore stated as unverified

**Whether Sideloadly strips entitlements that the free provisioning profile does
not support is not documented anywhere, and I could not establish it.** No FAQ
entry, changelog line or developer statement describes it. Both observable
outcomes are attested in the wild:

* install fails with `0xE8008016` — *"The executable was signed with invalid
  entitlements… do not match those specified in your provisioning profile"*; or
* install succeeds, the app launches, and the capability silently does not work.

The second is far more common, and it is the expected shape of the ProxyTunnel
outcome: the tunnel cannot be provisioned, so it will not run.

The underlying mechanics are worth understanding, because they explain why
"signing succeeded" does not imply "the entitlement works". Xcode performs a
provisioning-profile/entitlement consistency check at signing time; `codesign`
itself does not. Third-party tools skip that check, so they can produce a
signature that installs — and then iOS refuses to honour the entitlement at
runtime, because it validates the entitlement against the profile itself.

### Reports from people who tried exactly this

Every concrete report found has the same outcome: **it installs, it launches, the
tunnel never works.**

* PlayCover issue #1241: *"got Permission Denied when calling
  saveToPreferences()… Sideloading doesn't work either, as free accounts are not
  eligible for this entitlement."*
* AltStore issue #1091 (Orbot): *"everything works fine, but the Network
  Extension (aka 'VPN') cannot be installed, which is the main purpose of this
  app."*
* r/sideloaded, "VPN Profile": the user could add a VPN profile but *"it just
  won't start and crash log will say that the VPN plugin binary executable is not
  signed."*
* r/sideloaded, "VPN Apps?" (2025): *"You need the VPN entitlement which is only
  on paid certificates or paid developer accounts."*
* AltStore maintainer: *"'free' Apple Developers can't use the Networking
  Extension."*

No report was found of a free-Apple-ID tunnel actually working.

### What you see on the device afterwards

Two things share the VPN pane in Settings:

* the **Developer App** trust entry — Settings ▸ General ▸ VPN & Device
  Management ▸ your Apple ID ▸ Trust;
* a **VPN** row, if a configuration was created at all.

When the configuration cannot be created, iOS returns the generic code-5
"permission denied" and no row appears. When a configuration *is* created but the
extension cannot be launched, the row appears but is permanently unusable —
observers report it showing an "Update Required" state with the toggle greyed
out. Both are normal outcomes here.

Beware of confidently-quoted error strings in this area. The strings "Missing
entitlement", "No VPN profile" and "Failed to save configuration" do **not** exist
as real iOS Network Extension error text; they were searched for and not found.
This document does not use them.

---

## 8. Why not just use TrollStore?

TrollStore installs apps with arbitrary entitlements by abusing CoreTrust on
vulnerable iOS versions. It is not an option for a modern device:

* the jailed (non-jailbroken) range is **iOS 14.0b2 – 16.6.1, 16.7 RC (20H18),
  and 17.0 only**;
* **17.0.1 and later will never be supported** — the CoreTrust bug was fixed;
* TrollStore Lite covers 14.0 – 26.0.1 but requires a jailbreak.

All of iOS 17.1+, all of iOS 18 and all of iOS 26 are out of scope. Even where it
does apply, no official TrollStore documentation confirms that it grants the
Network Extension entitlement specifically; the best evidence is third-party.

This project does not provide exploitation instructions, and does not depend on
any of this.

---

## 9. Keychain, App Groups and free signing

**Keychain.** The default access group for an app is derived from its code
signature: `<TeamID>.<BundleID>`. Apple:

> When code signing your app, Xcode automatically prefixes the bundle ID with
> your team ID… and recognizes this app ID as the name of your app's default
> keychain access group… **If you don't specify any keychain access groups, then
> the app ID is the default.**

So a free-signed app can read and write its own Keychain items with **no extra
capability at all**. This is what the app does: `KeychainSecretStore` is created
with `accessGroup: nil`, deliberately. Re-signing the same bundle identifier with
the same Apple ID keeps the same default group, so passwords survive a re-sign.
(That last step is inference from Apple's derivation rule rather than an Apple
statement — MEDIUM confidence.)

What *cannot* be shared without the Keychain Sharing capability is a Keychain
item between the app and the extension, because their bundle identifiers differ
and therefore their default access groups do.

**App Groups.** Apple's table marks App Groups as available to free accounts —
contradicting the common belief that it is paid-only. However, registering a
group normally requires access to Certificates, Identifiers & Profiles, which a
free account does not have. Apple notes that you can *"create app groups when you
enable app groups in Xcode"* instead, but whether that path works on a Personal
Team is **unverified**.

This is why the app does not depend on App Groups. It checks at runtime whether
`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` returns a
container, checks the extension's provisioning profile for the App Groups
entitlement, and falls back to passing the credential inline in
`NETunnelProviderConfiguration` when either is missing. The Diagnostics screen
tells you which path is in use and what it means for credential storage.

---

## 10. Free account limits, verbatim

From Apple's account help pages:

> You can register up to 10 App IDs, which expire after 7 days.
>
> You can register up to 3 devices, which expire after 7 days.
>
> You can install up to 3 apps per device. Provisioning profiles that enable apps
> to be installed on a device will expire 7 days from issuance.

Note the wording: 10 App IDs **which expire after 7 days**, not "10 per week".
The "per week" phrasing that circulates widely is folklore.

Practical consequences:

* **An app with an app extension consumes more than one App ID**, because the
  extension gets its own. Sideloadly's UI shows the remaining weekly count.
* **The app stops working after 7 days.** Re-run Sideloadly with the same IPA.
* **Three apps maximum** on the device at once.
* Free accounts cannot access Certificates, Identifiers & Profiles at all.

Whether a Personal Team can embed an app extension *at all* has no explicit Apple
statement. The evidence points to yes — Apple's TN3125 scopes provisioning
profiles to "apps, app extensions, App Clips, system extensions, and XPC
Services", and Personal Team Xcode errors are capability-specific, which means
Xcode does reach profile creation for extension bundles — but it is rated MEDIUM,
not asserted.

---

## 11. Known failure modes when sideloading an IPA with an extension

Observed in the wild, and worth knowing if the install fails:

| Symptom | Cause |
|---|---|
| `PackageInspectionFailed` | The IPA's structure confused the installer. Check `PlugIns/` and the extension's `Info.plist` with `Scripts/validate-ipa.sh`. |
| `AppexBundleUnknownExtensionPointIdentifier` | The extension's `NSExtensionPointIdentifier` is not one iOS recognises. It must be `com.apple.networkextension.packet-tunnel`. |
| `AppexBundleIDNotPrefixed` | The extension's bundle identifier is not a child of the app's. Bundle-ID rewriting during free signing can break this. |
| `0xE8008016` | Signed entitlements do not match the provisioning profile. |
| Extension killed on launch (iOS 26) | Reported for `zsign`-signed appex bundles; Sideloadly appears to use `zsign`. |

The CI validation script checks the first three structurally, before you ever
download the artifact.

---

## 12. What actually works, and what does not

### Works with a free Apple ID, on a real iPhone

| Feature | Why it works |
|---|---|
| Adding, editing, deleting, selecting proxy profiles | Pure app logic |
| Field validation with specific, actionable messages | Pure logic |
| **Keychain-backed password storage** | The default access group needs no capability |
| **"Test connection" — a real end-to-end proxy check** | It opens a socket from the app process; no Network Extension involved |
| **Egress IP reporting** | The origin server tells you which IP it saw |
| Diagnostics: profile entitlements, routing plan, statistics | Read from the app's own bundle |
| Logs with credential redaction | App-local |
| Mock mode | Touches nothing |
| Auto-connect, DNS settings, on-demand preference | Stored; the on-demand rule only takes effect once a tunnel exists |

### Needs a paid Apple Developer Program membership

| Feature | Blocked by |
|---|---|
| Starting the packet tunnel | `com.apple.developer.networking.networkextension` — not provisionable |
| All traffic routed through the proxy | Same |
| DNS interception inside the tunnel | Same |
| UDP relay through SOCKS5 | Same |
| On-demand "block traffic while down" | Same |

### The honest bottom line

The proxy client, the userspace TCP/IP stack, the DNS interception, the UDP
relay, the credential handling and the diagnostics are all **implemented and
tested**. None of them is stubbed. What cannot be obtained for free is Apple's
permission to run them inside a Network Extension on a real device.

If you want a working VPN on your iPhone through your own proxy, the path is:
pay for the Apple Developer Program, sign the same IPA with a profile that
includes Network Extensions, and press CONNECT.

---

## Sources

The claims above with confidence labels and verbatim quotes are collected in
[`docs/research/`](research/):

* [`apple-entitlement-research-report.md`](research/apple-entitlement-research-report.md)
  — the capability table read from Apple's page DOM, the entitlement key and
  value, Personal Team restrictions, `NEVPNError` numeric values from the shipped
  header, and Apple DTS quotes.
* [`sideloadly-free-apple-id-report.md`](research/sideloadly-free-apple-id-report.md)
  — Sideloadly's documented behaviour, free-account limits, extension handling,
  and the reports from VPN-app attempts.
* [`vpn-sideload-free-apple-id-research.md`](research/vpn-sideload-free-apple-id-research.md)
  and [`trollstore-entitlements-research.md`](research/trollstore-entitlements-research.md)
  — the deeper dives.

Every factual claim in those reports carries a HIGH / MEDIUM / LOW / UNVERIFIED
label. Where the evidence ran out, they say so rather than filling the gap.
