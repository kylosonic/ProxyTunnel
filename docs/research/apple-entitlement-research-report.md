# Apple Network Extension / Code-Signing Research Report

**Scope:** entitlement and code-signing facts for a `NEPacketTunnelProvider` app extension on iOS, with emphasis on what a free ("Personal Team") Apple Account can and cannot do.

**Method:** all claims below come from live pages fetched during this research (developer.apple.com documentation JSON/HTML, Apple Developer Forums threads, Apple SDK headers, the Apple Developer Program License Agreement, and the Stack Exchange API). Verbatim quotes are reproduced exactly as retrieved. Where I could not find an authoritative source, the claim is explicitly labelled **UNVERIFIED** and I have not filled the gap with plausible text.

**Important caveat about recency:** the live Apple pages I fetched reflect a newer OS/Xcode generation than the "iOS 17/18 era, Xcode 16" context given in the task (the fetched pages reference Xcode 27 / iOS 27, and forum threads run through Feb 2026). I did not find evidence that any of the entitlement facts below changed between those generations. The one date correction that matters is in Question 4.

---

## Question 1 — Entitlement key, type, accepted value, and which bundles need it

**Answer.** The key is `com.apple.developer.networking.networkextension` (Apple's title for it is "Network Extensions Entitlement"). Its declared type is an **array of strings**, and `packet-tunnel-provider` is one of twelve documented accepted values. Your stated understanding — key `com.apple.developer.networking.networkextension`, value an array containing `packet-tunnel-provider` — is **confirmed**. On "both or only the extension": Apple's web documentation does not contain a single sentence stating this explicitly; the evidence I could obtain indicates it is required on the **extension** (unambiguously) and is also required on the **containing app** (strong evidence, but assembled from three independent sources rather than one Apple sentence).

**Evidence:**

- Apple's documentation JSON for the entitlement gives the exact key name and its declared type:
  - `"name": "com.apple.developer.networking.networkextension"` and `"value": [{"arrayMode": true, "baseType": "string "}]`
  - Title: `Network Extensions Entitlement`; Abstract: `The APIs an app can use to customize networking features.`
  - URL: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension
- The documented `Possible Values` list for that key contains exactly twelve strings: `dns-proxy`, `app-proxy-provider`, `content-filter-provider`, **`packet-tunnel-provider`**, `dns-proxy-systemextension`, `app-proxy-provider-systemextension`, `content-filter-provider-systemextension`, `packet-tunnel-provider-systemextension`, `dns-settings`, `app-push-provider`, `relay`, `url-filter-provider`.
- Apple's description attached to the `packet-tunnel-provider` value, verbatim: **"The APIs you use to tunnel IP packets to a remote network using any custom tunneling protocol."** (same URL)
- Apple's `Packet tunnel provider` API collection lists exactly one entry under **Essentials**: `doc://com.apple.documentation/documentation/BundleResources/Entitlements/com.apple.developer.networking.networkextension`. URL: https://developer.apple.com/documentation/networkextension/packet-tunnel-provider
- Apple's own instruction to obtain it, verbatim: **"To add this entitlement to an App Store app, enable the Network Extensions capability in Xcode."** (entitlement page, above)
- Apple DTS (Quinn "The Eskimo!", Developer Technical Support) on what a generated profile contains, verbatim: **"A newly generated profile will include the `com.apple.developer.networking.networkextension` entitlement in its allowlist; this is an array with an entry for each of the supported Network Extension providers."** — https://developer.apple.com/forums/thread/67613
- Evidence that the **containing app** also carries it: WireGuard's shipping iOS app target has the entitlement in its own entitlements file, not only in the extension:
  - `Sources/WireGuardApp/UI/iOS/WireGuard.entitlements` contains `com.apple.developer.networking.networkextension` → `<array><string>packet-tunnel-provider</string></array>`
  - `Sources/WireGuardNetworkExtension/WireGuardNetworkExtension_iOS.entitlements` contains the same key/value plus `com.apple.security.application-groups`.
  - URLs: https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardApp/UI/iOS/WireGuard.entitlements and https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardNetworkExtension/WireGuardNetworkExtension_iOS.entitlements
- Evidence that App Store distribution validates it on **both** bundles — a developer's upload was rejected twice, once for the `.appex` and once for the `.app`, verbatim from the App Store Connect error payload: `"detail" : "Missing Entitlement. The bundle 'Home Assistant.app/PlugIns/HomeAssistant-Extensions-PushProvider.appex' is missing entitlement 'com.apple.developer.networking.networkextension'."` and `"detail" : "Missing Entitlement. The bundle 'Home Assistant.app' is missing entitlement 'com.apple.developer.networking.networkextension'."` — https://stackoverflow.com/q/79153717
- Apple's system log evidence that the *containing app's* entitlement is what is checked when creating a VPN configuration: `nehelper: [com.apple.networkextension:] Created a new configuration delegate with name = …, bundleID = …, applicationID = …, entitled = 1, hasProviderPermission = 1` versus the failing case `entitled = 0, hasProviderPermission = 0` — https://developer.apple.com/forums/thread/816045

**Caveat:** I did **not** find an Apple sentence of the form "the containing app must also have this entitlement". The "both" conclusion is an inference from Apple's App Store validation behavior, Apple's own DTS guidance to enable the capability on the targets involved, and production app structure. Treat the *extension* requirement as certain and the *containing app* requirement as very strongly supported but not stated in one Apple sentence.

---

## Question 2 — Is Network Extensions (`packet-tunnel-provider`) available to Personal Teams?

**Answer.** **No.** Apple's "Supported capabilities (iOS)" page marks **Network extensions** and **Personal VPN** as available to the Apple Developer Program (ADP) and Apple Developer Enterprise Program (ADEP) columns only — the free column is blank. **App groups** and **Keychain sharing**, by contrast, **are** marked as available to the free column. One naming caveat: the page's third column is labelled **"Apple Developer"**, not literally "Personal Team"; Apple defines that column as Apple Account holders who accepted the Apple Developer Agreement at no cost, and Apple's account help defines "Personal Team" as exactly the account state where "your account is not associated with a developer program membership". The two therefore describe the same population, and a Stack Overflow answer independently maps the table's last column to the free tier.

**The table is reproduced verbatim (all 57 rows) at the end of this section.**

**Evidence:**

- Header row of the capability table, verbatim: `Capability` | `ADP` | `ADEP` | `Apple Developer`. URL: https://developer.apple.com/help/account/reference/supported-capabilities-ios/
- Column definitions, verbatim from the page's list descriptors:
  - **"ADP:** Apple Developer Program membership. Members of this paid program can distribute apps on the App Store."
  - **"ADEP:** Apple Developer Enterprise Program membership. Members of this paid program can distribute apps to employees within an organization."
  - **"Apple Developer:** Apple Account holders who have agreed to the Apple Developer Agreement to access certain resources on the Apple Developer website. No cost is associated with this agreement and developers can't distribute apps."
- Raw HTML for the four rows specifically asked about (each `<figure class="icon icon-checksolid" alt="yes">` is a check mark; an empty `<td></td>` is blank):
  - **Network extensions** → ADP ✓, ADEP ✓, Apple Developer **blank**
  - **Personal VPN** → ADP ✓, ADEP ✓, Apple Developer **blank**
  - **App groups** → ADP ✓, ADEP ✓, Apple Developer **✓**
  - **Keychain sharing** → ADP ✓, ADEP ✓, Apple Developer **✓**
- Apple's definition of "Personal Team", verbatim: **"To install and test your apps on a personal device, you'll need to sign in to your Apple Account in Xcode. If your account is not associated with a developer program membership, Xcode will indicate it's a Personal Team."** — https://developer.apple.com/help/account/basics/about-your-developer-account
- Independent corroboration that the last column is the free tier, and that it excludes these two capabilities — accepted answer, verbatim: **"The free tier 'Apple Developer' cannot add network extensions or personal VPN capabilities. You will need a paid Apple Developer Program membership."** — https://stackoverflow.com/q/77974220
- Apple's general statement that membership gates capabilities, verbatim: **"The platform, and whether you're a member of the Apple Developer Program, may limit the capabilities available to your app. For the supported capabilities, go to the Reference section of …"** — https://developer.apple.com/documentation/xcode/adding-capabilities-to-your-app
- The actual Xcode failure text seen by a free/Personal Team developer, verbatim: **"Personal development teams , including 'My Name' do not support Network Extensions Capability"** — https://developer.apple.com/forums/thread/675195 (and the sibling form **"Personal development teams, including ……, do not support the System Extension and Network Extensions capabilities."** — https://stackoverflow.com/q/64859177)

### Full capability table as published (verbatim from the page)

✓ = check mark on the page; — = blank cell. "Apple Developer" is the free tier.

| Capability | ADP | ADEP | Apple Developer (free) |
|---|---|---|---|
| 5G Network Slicing | ✓ | ✓ | — |
| Access WiFi information | ✓ | ✓ | — |
| App Attest | ✓ | ✓ | — |
| App groups | ✓ | ✓ | **✓** |
| Apple Pay | ✓ | — | — |
| Associated domains | ✓ | ✓ | — |
| AutoFill credential provider | ✓ | ✓ | — |
| Background modes | ✓ | ✓ | **✓** |
| ClassKit | ✓ | ✓ | — |
| Communication Notifications | ✓ | ✓ | — |
| Data protection | ✓ | ✓ | **✓** |
| DriverKit Family MIDI * | ✓ | ✓ | — |
| Extended Virtual Addressing | ✓ | ✓ | — |
| Family Controls (development) * | ✓ | — | — |
| FileProvider Testing Mode * | ✓ | ✓ | — |
| Fonts | ✓ | ✓ | — |
| Game Center | ✓ | — | — |
| Group Activities | ✓ | ✓ | — |
| Head Pose | ✓ | ✓ | — |
| HealthKit | ✓ | ✓ | **✓** |
| HealthKit Estimate Recalibration | ✓ | ✓ | — |
| HLS Interstitial Previews | ✓ | — | — |
| HomeKit | ✓ | ✓ | **✓** |
| Hotspot | ✓ | ✓ | — |
| iCloud: CloudKit | ✓ | ✓ | — |
| iCloud: iCloud documents | ✓ | ✓ | — |
| iCloud: iCloud key-value storage | ✓ | ✓ | — |
| ID Verifier - Display Only | ✓ | ✓ | — |
| In-App Purchase | ✓ | — | — |
| Increased Debugging Memory Limit | ✓ | ✓ | — |
| Inter-App Audio | ✓ | ✓ | **✓** |
| Journaling Suggestions | ✓ | — | — |
| Keychain sharing | ✓ | ✓ | **✓** |
| Low Latency HLS | ✓ | — | — |
| Maps | ✓ | ✓ | **✓** |
| Matter Allow Setup Payload | ✓ | ✓ | — |
| MDM Managed Associated Domains | ✓ | ✓ | — |
| Media Device Discovery | ✓ | ✓ | — |
| Messages Collaboration | ✓ | — | — |
| Multipath | ✓ | ✓ | — |
| Near Field Communication (NFC) Tag Reading | ✓ | ✓ | — |
| **Network extensions** | **✓** | **✓** | **—** |
| On Demand Install Capable | ✓ | — | — |
| **Personal VPN** | **✓** | **✓** | **—** |
| Push to Talk | ✓ | ✓ | — |
| Push notifications | ✓ | ✓ | — |
| Sensitive Content Analysis | ✓ | — | — |
| Shared with You | ✓ | — | — |
| Sign in with Apple | ✓ | — | — |
| SIM Inserted for Wireless Carriers | ✓ | ✓ | — |
| Siri | ✓ | ✓ | — |
| Spatial Audio Profile | ✓ | ✓ | — |
| Sustained Execution | ✓ | ✓ | — |
| Time Sensitive Notifications | ✓ | ✓ | — |
| Wallet | ✓ | ✓ | — |
| WeatherKit | ✓ | — | — |
| Wireless Accessory Configuration | ✓ | ✓ | **✓** |

Page note, verbatim: `* Development only`. Also noted on the page: **"If you aren't a member of the Apple Developer Program, you can use the MapKit framework but you can't provide routing directions. The ability to upload geolocation files in App Store Connect is only included with membership in the Apple Developer Program."**

*(Note: the page HTML contains one malformed row — "Sensitive Content Analysis" — that uses `colspan="6"/"2"/"2"/"2"`. It does not affect any row in the table above.)*

---

## Question 3 — What exactly happens at runtime without the entitlement

**Answer.** The honest summary is that **most of this scenario is UNVERIFIED**, because a build lacking the entitlement cannot be produced or installed in the first place on the configurations I could find documented — the failure happens at signing/provisioning time, not at runtime (see Question 4). Where developers did reach runtime with only *part* of the required entitlements (Personal VPN without Network Extensions), the observed failure was `NEVPNErrorDomain` **code 5** `"permission denied"` on `saveToPreferences`, plus `NEConfigurationErrorDomain` code 10. On the extension process: Apple documents no iOS behavior for this case, but the analogous documented macOS failure shows the extension is **not registered at all** (`Found 0 registrations for … (com.apple.networkextension.packet-tunnel)`), i.e. it never launches. I found no authoritative statement about `loadAllFromPreferences` in this scenario, and none about whether the "App would like to add VPN Configurations" alert appears.

**One correction to your premise:** `NEVPNErrorDomain` **code 5 is NOT `configurationStale`**. Per Apple's shipped SDK header, code 4 is `ConfigurationStale` and code 5 is `ConfigurationReadWriteFailed`.

**Evidence — the NEVPNError enum, verbatim from Apple's SDK header** (`NEVPNManager.h` in the NetworkExtension framework):

```objc
typedef NS_ENUM(NSInteger, NEVPNError) {
    /*! @const NEVPNErrorConfigurationInvalid The VPN configuration is invalid */
    NEVPNErrorConfigurationInvalid = 1,
    /*! @const NEVPNErrorConfigurationDisabled The VPN configuration is not enabled. */
    NEVPNErrorConfigurationDisabled = 2,
    /*! @const NEVPNErrorConnectionFailed The connection to the VPN server failed. */
    NEVPNErrorConnectionFailed = 3,
    /*! @const NEVPNErrorConfigurationStale The VPN configuration is stale and needs to be loaded. */
    NEVPNErrorConfigurationStale = 4,
    /*! @const NEVPNErrorConfigurationReadWriteFailed The VPN configuration cannot be read from or written to disk. */
    NEVPNErrorConfigurationReadWriteFailed = 5,
    /*! @const NEVPNErrorConfigurationUnknown An unknown configuration error occurred. */
    NEVPNErrorConfigurationUnknown = 6,
} API_AVAILABLE(macos(10.11), ios(8.0)) API_UNAVAILABLE(tvos) __WATCHOS_PROHIBITED;

/*! @const NEVPNErrorDomain The VPN error domain */
NEVPN_EXPORT NSString * const NEVPNErrorDomain
```

Source: https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/System/Library/Frameworks/NetworkExtension.framework/Versions/A/Headers/NEVPNManager.h (a mirror of Apple's shipped SDK header). Apple's own web documentation confirms the six case **names** and their meanings but does **not** publish the numeric raw values:

- `configurationDisabled` — "An error code that indicates the VPN configuration associated with the VPN manager isn't enabled." + "This error can occur when trying to start the VPN connection."
- `configurationInvalid` — "An error code that indicates the VPN configuration associated with the VPN manager object is invalid."
- `configurationStale` — "An error code that indicates another process modfied the VPN configuration since the last time the app loaded the configuration." + "This error also occurs if the app tries to save the VPN configuration before loading it from the Network Extension preferences the first time after the app launches."
- URL: https://developer.apple.com/documentation/networkextension/nevpnerror-swift.struct/code

**Evidence — what `startTunnel` documents as its error set.** From `NETunnelProviderSession.h`, verbatim:

```
 * @param error If the tunnel was started successfully, this parameter is set to nil. Otherwise this parameter is set to the error that occurred. Possible errors include:
 *    1. NEVPNErrorConfigurationInvalid
 *    2. NEVPNErrorConfigurationDisabled
```

Source: https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX11.3.sdk/System/Library/Frameworks/NetworkExtension.framework/Versions/A/Headers/NETunnelProviderSession.h — i.e. `startTunnel(options:)` is documented to fail with code 1 or code 2; there is no documented "missing entitlement" code.

**Evidence — `loadAllFromPreferences` documents no specific code.** From `NETunnelProviderManager.h`, verbatim: **"This function asynchronously reads all of the NETunnelProvider configurations created by the calling app that have previously been saved to disk and returns them as NETunnelProviderManager objects. … The array passed to the block may be empty if no NETunnelProvider configurations were successfully read from the disk. The NSError passed to this block will be nil if the load operation succeeded, non-nil otherwise."** — same SDK mirror, `NETunnelProviderManager.h`. **What it actually returns in the missing-entitlement case is UNVERIFIED.**

**Evidence — observed runtime failure with *partial* entitlements (`saveToPreferences`):**

- `Error Domain=NEVPNErrorDomain Code=5 "permission denied"` when calling `saveToPreferences` on `NETunnelProviderManager`; the asker stated **"I have Personal VPN enabled in Capabilities and have .entitlements files in both app and network extension."** Top answers blamed the missing **Network Extensions** capability: **"Sounds like your app is not capable (doesn't have permission) for reading or writing the Network Extension preferences. Check on developer.apple.com at your app's ID that it uses Network Extensions and Personal VPN."** — https://stackoverflow.com/q/41957328
- The same code, plus a second domain, in a case where the developer had **only** Personal VPN and no Network Extensions, verbatim from their log:
  - `Failed to save configuration docks-2: Error Domain=NEConfigurationErrorDomain Code=10 "permission denied" UserInfo={NSLocalizedDescription=permission denied}`
  - `Failed to save configuration: Error Domain=NEVPNErrorDomain Code=5 "permission denied" UserInfo={NSLocalizedDescription=permission denied}`
  — https://stackoverflow.com/q/73728268
  - Note the localized description is `permission denied`, which is consistent with code 5 = `ConfigurationReadWriteFailed` ("cannot be read from or written to disk") rather than code 4 = `ConfigurationStale`.
- `Error Domain=NEVPNErrorDomain Code=1 "(null)"` from `startVPNTunnelAndReturnError:` where `saveToPreferences` had succeeded; the accepted answer was **"I discovered that if I call `loadFromPreferencesWithCompletionHandler:` before trying to start the tunnel (but after `saveToPreferencesWithCompletionHandler`), this error goes away"** — i.e. code 1 here is the documented `ConfigurationInvalid`, matching Apple's note that `configurationStale` arises from saving before loading. URL: https://stackoverflow.com/q/35325487

**Evidence — does the extension process launch?** Apple documents no iOS case. The closest documented behaviour is on macOS, where removing a required entitlement caused the system to find **zero** registrations for the extension point, verbatim from the reporter's log:

```
Failed to find an app extension with identifier app.acmeVpnM.extension and extension point com.apple.networkextension.packet-tunnel: (null)
Found 0 registrations for app.acmeVpnM.extension (com.apple.networkextension.packet-tunnel)
```

— https://developer.apple.com/forums/thread/784800. Apple DTS's answer there was unrelated to registration and stated **"On macOS, App Sandbox is mandatory: For all Network Extension app extensions …"**. **Applying this to the iOS missing-`networkextension` case is an inference, not a verified fact.**

**Evidence — system-side gating:** Apple's `nehelper` logs show the system explicitly tracks whether the caller is entitled, verbatim: `Created a new configuration delegate with name = ***, bundleID = ***, applicationID = ***, entitled = 0, hasProviderPermission = 0` followed by `*** Failed to obtain authorization right for 3: no authorization provided` — https://developer.apple.com/forums/thread/816045. This confirms the system computes an entitlement/provider-permission verdict and denies the operation, but does not by itself tell us which API returns which code.

**Evidence — the permission alert.** Apple documents the alert's existence for Personal VPN, verbatim: **"The user must explicitly authorize your app the first time it saves a VPN configuration."** — https://developer.apple.com/documentation/networkextension/personal-vpn. **Whether the "App would like to add VPN Configurations" alert is suppressed when the entitlement is missing is UNVERIFIED.** The only related datapoint is a developer noting that after obtaining "the proper provisioning profile" they **"was able to see the popup confirming I want to add a VPN"**, implying the popup is tied to a successful save — https://stackoverflow.com/q/35325487.

---

## Question 4 — Minimum membership, and whether a special request is still required

**Answer.** A **paid Apple Developer Program membership** is the minimum; a Personal Team cannot obtain a profile containing `packet-tunnel-provider`. **No special request or approval form is required** — the capability is self-service for paid accounts and has been since **November 2016**, *not* 2019. Two exceptions still require Apple authorisation: **Network Extension app push providers** (`NEAppPushProvider`, iOS 14+) and **Hotspot Helper** (`NEHotspotHelper`). Separately, the Apple Developer Program License Agreement still contains a legal clause conditioning Network Extension use on having "received an entitlement from Apple" and reserving Apple's right to withhold or revoke it.

**Evidence — the authoritative Apple DTS post, verbatim** (Quinn "The Eskimo!", Developer Technical Support, Apple; thread created Nov '16, revision history through 2025-11-11):

> **"Originally, using any of these facilities required authorisation from Apple. Specifically, you had to apply for, and be granted access to, a managed capability. In Nov 2016 this policy changed for Network Extension providers. Any developer can now use the Network Extension provider capability like they would any other capability."**

> **"There is one exception to this rule: Network Extension app push providers, introduced by iOS 14 in 2020, still requires that Apple authorise the use of a managed capability."**

> **"Also, the situation with Hotspot Helpers remains the same: Using a Hotspot Helper, requires that Apple authorise that use via a managed capability."**

> **"#2 — How exactly do I enable the Network Extension provider capability? In the Signing & Capabilities editor, add the Network Extensions capability and then check the box that matches the provider you're creating. In the Certificates, Identifiers & Profiles section of the Developer website, when you add or edit an App ID, you'll see a new capability listed, Network Extensions. Enable that capability in your App ID and then regenerate the provisioning profiles based on that App ID."**

URL: https://developer.apple.com/forums/thread/67613 — thread title "Network Extension Framework Entitlements".

**Evidence — Apple DTS, answered 2026, verbatim:**

> Question: *"I am writing to inquire about the process for obtaining approval for the following entitlement…"*
> **"There is no approval process for this. Most NE entitlements, including the one for content filters, are available to all (paid) developers."**
> **"Note — Historically there was an approval process for this but that's not been the case for almost 10 years now."**

URL: https://developer.apple.com/forums/thread/816877 ("Request for Guidance on Approval Process for Network Extension Entitlement")

**Evidence — Apple DTS confirming the paid-team requirement and pointing at the capability reference page, verbatim:**

> Question: *"So I take that as a no I don't need to request anything from Apple and the option in Xcode is all I need? … the option in Xcode is all I need?"*
> **"Correct [1]."**
> Footnote **[1]**: **"Assuming that: You're creating one you're part of a paid developer team. See Developer Account Help > Reference > Supported capabilities (iOS). You're creating a packet tunnel provider. You're not concerned with MDM deployment."**

URL: https://developer.apple.com/forums/thread/816045 ("Do I need to request Packet Tunnel Provider entitlement from Apple to get my app working?")

**Evidence — Apple DTS, verbatim** (Matt Eaton, DTS Engineering, CoreOS; Mar 2021):

> Question: *"…Xcode returns this error 'Personal development teams , including 'My Name' do not support Network Extensions Capability' … is there a way to debug the project while i am just trying to proof the concept?"*
> **"Not without code signing with the Network Extension capability tied to your Developer Account."**

URL: https://developer.apple.com/forums/thread/675195

**Evidence — the License Agreement clause, verbatim** (Apple Developer Program License Agreement, §3.3.3 "Data and Privacy", subsection **G. Network Extension Framework**):

> **"Your Application must not access the Network Extension Framework unless Your Application is primarily designed for providing networking capabilities, and You have received an entitlement from Apple for such access."**

> **"Apple reserves the right to not provide You with an entitlement to use the Network Extension Framework in its sole discretion and to revoke such entitlement at any time."**

URL: https://developer.apple.com/support/terms/apple-developer-program-license-agreement/

**Interpretation caveat:** the DPLA's "received an entitlement from Apple" is satisfied by obtaining the capability through the normal self-service mechanism; it is a separate matter from the pre-2016 managed-capability approval. I am flagging it because it uses approval-flavoured language and is the kind of clause that gets quoted out of context. **Whether the DPLA clause has ever been enforced to require a separate approval since Nov 2016 is UNVERIFIED.**

---

## Question 5 — Free / Personal Team limits

**Answer.** Apple publishes the concrete limits directly. A free account is limited to **10 App IDs (expiring after 7 days)**, **3 devices (expiring after 7 days)**, and **3 apps installed per device**, with **provisioning profiles expiring 7 days from issuance**. Free accounts also do **not** get Certificates, Identifiers & Profiles (the developer-portal capability management UI). One correction to your premise: Apple says **"up to 10 App IDs, which expire after 7 days"** — it does not say "10 App IDs per 7 days"; the "10 per week" phrasing is community folklore (and appears in an old Stack Overflow answer), not Apple's wording.

**Evidence — Apple's account help page, verbatim** (this is the single authoritative source for all of the following):

> **"Enable a personal team in Xcode — To install and test your apps on a personal device, you'll need to sign in to your Apple Account in Xcode. If your account is not associated with a developer program membership, Xcode will indicate it's a Personal Team. Your account's App IDs, devices, certificates, and provisioning profiles are managed directly in Xcode, and you'll be required to reprovision your apps to a device periodically."**

> **"You can register up to 10 App IDs, which expire after 7 days."**

> **"You can register up to 3 devices, which expire after 7 days."**

> **"You can install up to 3 apps per device. Provisioning profiles that enable apps to be installed on a device will expire 7 days from issuance. You'll need to rebuild and reinstall your app to your device after expiration."**

URL: https://developer.apple.com/help/account/basics/about-your-developer-account

**Evidence — free accounts lack the portal's Certificates, Identifiers & Profiles.** From the same page's feature comparison table (header row `Feature | Registered for free | Apple Developer Program member | Apple Developer Enterprise Program member`), the free column has a check for "On-device testing using Xcode" and **no** check for **"Certificates, Identifiers & Profiles"**. Free does get: Beta Xcode and OS releases; On-device testing using Xcode; Apple Developer Forums; Feedback Assistant; Meet with Apple activities. Free does **not** get: Code-level support; Certificates, Identifiers & Profiles; Mac software notarization; App Store Connect; TestFlight; Xcode Cloud. (Same URL.)

**Evidence — the "number of app extensions per app" is not documented by Apple.** I searched Apple's account help and capability reference pages and found no statement limiting how many app extensions an app may contain under free provisioning. **That specific limit is UNVERIFIED.**

---

## Question 6 — Does free provisioning support embedding an app extension at all?

**Answer.** **I could not find an Apple source that answers this directly**, so the headline claim below is labelled MEDIUM rather than HIGH. The evidence that does exist points to **yes**: the Personal Team flow provisions *bundles*, and Apple's own technote defines provisioning profiles as covering "apps, app extensions, App Clips, system extensions, and XPC Services"; Apple's free-tier capability table grants capabilities that extensions commonly need (App groups, Keychain sharing, Background modes); and the real-world Xcode errors Personal Team users hit are *capability-specific* ("do not support the Network Extensions capability"), which shows Xcode does reach the point of creating a profile for the extension bundle. Two practical constraints apply: each extension consumes one of the 10 App IDs, and the whole app still counts against the 3-apps-per-device and 7-day limits.

**Evidence — profiles cover app extensions, verbatim** (Apple Technote TN3125):

> **"In this document the term [app] refers to a main executable packaged in a bundle structure. This encompasses apps, app extensions, App Clips, system extensions, and XPC Services."**

URL: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles

**Evidence — Xcode provisions the extension bundle under a Personal Team, and fails only on the specific capability.** Real error text reported by a Personal Team developer, verbatim:

> **"Cannot create a Mac App Development provisioning profile for 'com.example.ExampleCam.ExampleCam'. Personal development teams, including \*\*\*, do not support the System Extension capability."**

URL: https://stackoverflow.com/q/63476574 (comment on the accepted answer)

> **"No profiles for 'com.example.apple-samplecode.SimpleFirewall8FTGRDPGFZ' were found"** / **"Personal development teams, including ….., do not support the System Extension and Network Extensions capabilities."**

URL: https://stackoverflow.com/q/64859177

Note the form of these messages: the provisioning attempt for a bundle happened, and the failure is attributed to a *named capability*, not to app extensions being unsupported.

**Evidence — a Personal Team developer successfully built and ran an app containing an app extension** (a File Provider extension), verbatim: **"The app and its extension have a common app group set up in their entitlements and are signed automatically with my personal team and a development certificate. I built and ran my app and extension."** The problem they hit was unrelated to provisioning (the extension never appeared because they had not registered a File Provider domain). URL: https://stackoverflow.com/q/66546696

**Evidence — capabilities a free team *can* use that extensions commonly require:** App groups ✓, Keychain sharing ✓, Background modes ✓, Data protection ✓ (Apple's capability table, Question 2 above).

**Explicit gap:** there is **no Apple sentence** stating "free provisioning supports app extensions". Whether a *Share Extension* or *Widget* specifically builds and installs on a Personal Team is therefore **MEDIUM confidence (strong inference), not verified from Apple**. What *is* verified is that an extension requiring the Network Extensions capability cannot be provisioned by a Personal Team at all — that is a hard block at signing time, before any runtime question arises.

---

## Question 7 — App Groups on Personal Teams

**Answer.** **Apple's capability reference says App Groups *is* available to free accounts** — it is one of only nine capabilities with a check in the "Apple Developer" (free-tier) column. However, *enabling* App Groups requires registering a group identifier, and Apple documents that portal registration as requiring "Account Holder or Admin" role in Certificates, Identifiers & Profiles — which free accounts cannot access at all. Apple does say you can alternatively create app groups from Xcode. I could **not** verify end-to-end whether Xcode successfully creates an App Group under a Personal Team, and I found no Apple statement either way. Practically, this question is moot for your use case: a packet tunnel provider cannot be provisioned on a Personal Team in the first place (Question 2/4).

**Evidence — the capability is marked available to free accounts.** In the raw HTML table row for **App groups**, all three columns contain a check: `<td><figure class="icon icon-checksolid" alt="yes"></figure></td>` for ADP, ADEP, **and** Apple Developer. URL: https://developer.apple.com/help/account/reference/supported-capabilities-ios/ (see Question 2 table.)

**Evidence — enabling it requires portal registration, verbatim:**

> **"You'll need to register one or more groups to enable app groups. Required role: Account Holder or Admin. In Certificates, Identifiers & Profiles, click Identifiers in the sidebar, then click the add button (+) on the top left. Select App Groups, then click continue. Enter a description and identifier, click Continue, then click Register. Alternatively, you can create app groups when you enable app groups in Xcode."**

URL: https://developer.apple.com/help/account/identifiers/register-an-app-group

**Evidence — free accounts have no Certificates, Identifiers & Profiles access** (Question 5, feature table on https://developer.apple.com/help/account/basics/about-your-developer-account).

**Evidence — App Groups also lists extra setup steps even for entitled accounts, verbatim:**

> **"Note: The following app capabilities require additional steps: Sign in with Apple, App groups, Apple Pay, Data protection, iCloud, and push notifications."**

URL: https://developer.apple.com/help/account/identifiers/enable-app-capabilities

**Evidence — contradicting (but dated and non-Apple) datapoint, for completeness.** The only direct developer report I found on App Groups and free accounts is old and predates free provisioning entirely (asked 2015-04-23, answered 2015-06-22, before Xcode 7 introduced Personal Teams): *"Is it possible to enable app groups without being enrolled in a developer program?"* → **"Nope you need to be in a developer program for this"**. URL: https://stackoverflow.com/q/29826086. I do **not** treat this as current evidence.

**Explicit gap:** whether Xcode's "create app groups… in Xcode" path actually succeeds for a Personal Team is **UNVERIFIED**. I found no Apple documentation and no reliable recent developer report establishing either outcome. Note that the widely repeated Xcode error string *"The 'X' feature is only available to users enrolled in the Apple Developer Program"* — which I **did** verify for Push Notifications (https://stackoverflow.com/q/37522049) — I could **not** find attested for App Groups.

---

## Question 8 — Keychain Sharing and the default access group for a Personal-Team-signed app

**Answer.** Keychain Sharing is available to free accounts per Apple's capability table, but the more important fact is that **you do not need the Keychain Sharing capability at all to store and read your own generic passwords**: Apple documents that an app is always a member of at least one group containing only itself, whose name is the **App ID** = `<teamID>.<bundleID>`, and that this App ID is the app's **default** access group when no keychain access groups are specified. Because the group name is derived from the team ID and bundle ID — both stable for a given Apple Account + bundle ID — a Personal-Team-signed app should be able to read a generic password it stored earlier across re-signs, as long as neither the Apple Account nor the bundle ID changes. **The "stable across re-signs" step is my inference from the documented derivation, not an Apple statement**, so it is labelled MEDIUM.

**Evidence — Apple's Keychain Services documentation, verbatim:**

> **"When you create a new app you assign it a bundle ID, typically using reverse DNS notation, with a string like `com.example.AppOne`. When code signing your app, Xcode automatically prefixes the bundle ID with your team ID — the unique character sequence issued by Apple to each development team — and … recognizes this app ID as the name of your app's default keychain access group by including it in your access group array: `[$(teamID).com.example.AppOne]`"**

> **"Because app IDs are unique across apps, and because the app ID is stored in an entitlement protected by code signing, no other app can use it, therefore no other app is in this group. Any keychain items stored with this access group are private to App One."**

> **"Second, order matters. The system considers the first item in the list of access groups to be the app's default access group. This is the access group that keychain services assumes if you don't otherwise specify one. … If you don't specify any keychain access groups, then the app ID is the default."**

> **"An access group is a logical collection of apps tagged with a particular group name string. Any app in a given group can share keychain items with all the other apps in the same group. You can add an app to any number of groups, but the app is always part of at least one group that contains only itself. That is, an app can always store and retrieve private keychain items, regardless of whether it also participates in other groups."**

> **"If you don't specify any access group when adding an item, keychain services applies your app's default access group…"**

URL: https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps

**Evidence — the capability is available to free accounts.** "Keychain sharing" row: ADP ✓, ADEP ✓, Apple Developer **✓** — https://developer.apple.com/help/account/reference/supported-capabilities-ios/ (Question 2 table).

**Evidence — Apple's technote shows the profile grants a wildcard and the app claims the concrete App ID, verbatim:**

> **"Every entitlement claimed by the app must be in the profile's allowlist but the reverse isn't true. It's fine for the allowlist to include entitlements that the app doesn't claim."**

> Profile allowlist example: `<key>keychain-access-groups</key><array><string>SKMME9E2Y8.*</string><string>com.apple.token</string></array>`
> App's claimed entitlements example: `<key>keychain-access-groups</key><array><string>SKMME9E2Y8.com.example.apple-samplecode.ProfileExplainer</string><string>SKMME9E2Y8.com.example.apple-samplecode.shared</string></array>`
> **"Note that the `keychain-access-groups` value, `SKMME9E2Y8.com.example.apple-samplecode.ProfileExplainer`, starts with `SKMME9E2Y8.` and thus is allowed by the wildcard."**

URL: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles

**Evidence — the entitlement key is `keychain-access-groups`.** Apple's entitlement reference gives `"name": "keychain-access-groups"` with `"value": [{"arrayMode": true, "baseType": "string "}]`, titled "Keychain Access Groups Entitlement"; its entire Discussion is: **"To add this entitlement to your app, enable the Keychain Sharing capability in Xcode."** — https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups

**Explicit gap — the re-sign stability claim.** Apple never says "the default access group remains stable across re-signs". My reasoning is that the group name is `<teamID>.<bundleID>` and both components are stable for a fixed Apple Account and bundle ID, and that the access group is written into the keychain item at store time. **UNVERIFIED by an Apple statement.** Likewise, the widely reported consequence that **enrolling in the paid program later changes the team ID and orphans previously stored keychain items is UNVERIFIED** — I found no Apple source confirming or denying it.

---

## Question 9 — Personal VPN (`com.apple.developer.networking.vpn.api`): needed for packet tunnels today?

**Answer.** They are **two separate entitlements for two separate APIs**, and today a `NEPacketTunnelProvider` does **not** need `com.apple.developer.networking.vpn.api`. Apple's own API collections pair them explicitly: the "Packet tunnel provider" collection lists the **Network Extensions** entitlement as its Essentials, while the "Personal VPN" collection lists the **Personal VPN** entitlement as its Essentials. The Personal VPN entitlement's documentation scopes it to `NEVPNManager` (the legacy built-in IPsec/IKEv2 path). WireGuard's shipping iOS app and its packet-tunnel extension currently carry **only** `com.apple.developer.networking.networkextension` and contain **zero** references to `vpn.api` anywhere in the repository. Historically, community answers from 2016–2017 did say both were required — that advice is stale, but I found no Apple sentence explicitly retracting it, so the "not required today" conclusion is MEDIUM-HIGH rather than HIGH.

**Evidence — the two collections pair each API with its own entitlement:**

- "Packet tunnel provider" → `## Essentials` contains exactly `doc://com.apple.documentation/documentation/BundleResources/Entitlements/com.apple.developer.networking.networkextension`. URL: https://developer.apple.com/documentation/networkextension/packet-tunnel-provider
- "Personal VPN" → `## Essentials` contains exactly `doc://com.apple.documentation/documentation/BundleResources/Entitlements/com.apple.developer.networking.vpn.api`. URL: https://developer.apple.com/documentation/networkextension/personal-vpn
- The Personal VPN collection's abstract scopes it: **"Create and manage a VPN configuration that uses one of the built-in VPN protocols (IPsec or IKEv2)."**

**Evidence — the Personal VPN entitlement's own documentation, verbatim:**

> **"With the [Personal VPN entitlement] enabled, your app can use the [NEVPNManager] class to manage a Personal VPN configuration."**
> **"To add this entitlement to your app, enable the Personal VPN capability in Xcode. When the entitlement is enabled, Xcode sets the value to `allow-vpn`."**

Key name `com.apple.developer.networking.vpn.api`, type array of strings, single documented possible value `allow-vpn`. URL: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.vpn.api

**Evidence — both are unavailable to free/Personal Teams.** Rows "Network extensions" and "Personal VPN" are each ADP ✓ / ADEP ✓ / Apple Developer — (Question 2).

**Evidence — a production packet tunnel provider uses only the Network Extensions entitlement.** WireGuard's current `master` entitlements files:

- App (`Sources/WireGuardApp/UI/iOS/WireGuard.entitlements`): `com.apple.developer.networking.networkextension` → `[packet-tunnel-provider]`, plus `com.apple.developer.networking.wifi-info` and `com.apple.security.application-groups`. **No `com.apple.developer.networking.vpn.api`.**
- Extension (`Sources/WireGuardNetworkExtension/WireGuardNetworkExtension_iOS.entitlements`): `com.apple.developer.networking.networkextension` → `[packet-tunnel-provider]`, plus `com.apple.security.application-groups`. **No `com.apple.developer.networking.vpn.api`.**
- A repository-wide GitHub code search for `vpn.api` within `WireGuard/wireguard-apple` returned **0 results**.
- URLs: https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardApp/UI/iOS/WireGuard.entitlements , https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardNetworkExtension/WireGuardNetworkExtension_iOS.entitlements

**Evidence — the historical "you need both" advice (now stale):**

- 2016 accepted answer, verbatim: **"Edit your App ID on Apple's dev portal and look for the Network Extensions capability/service. You also need Personal VPN to create and manage configurations in your app."** — https://stackoverflow.com/q/40285863
- 2017 answers to a `saveToPreferences` failure, verbatim: **"Check on developer.apple.com at your app's ID that it uses Network Extensions and Personal VPN."** and **"Go to Xcode -> Project -> Targets -> Capabilities and Enable VPN and Enable Network Extensions."** — https://stackoverflow.com/q/41957328
- Note that in the WireGuard case the app also does **not** claim `vpn.api`, and that a 2025 Apple DTS answer describes an app that "creates and saves the VPN profile itself using NETunnelProviderManager and saveToPreferences(), which works perfectly" with no mention of Personal VPN being needed — https://developer.apple.com/forums/thread/806802

**Explicit gap:** no Apple sentence of the form "`com.apple.developer.networking.vpn.api` is not required for `NEPacketTunnelProvider`" exists in the sources I found. The conclusion rests on Apple's Essentials pairings plus production evidence.

---

## Question 10 — Forum / Stack Overflow threads on running NEPacketTunnelProvider under a free/personal team

**Answer.** I found several directly relevant threads, including an Apple DTS engineer answering the exact question. The single most important finding is structural: **there is no "what happens at runtime" thread, because the attempt never reaches runtime** — the build/provisioning step fails first with a capability-specific error. The clearest statement of the block is Apple DTS's reply on thread 675195.

**Evidence — threads and what happened:**

1. **Apple Developer Forums 675195 — "Network Extension Capability"** (Mar 2021). A developer on a Personal Team building a content filter got Xcode error **"Personal development teams , including 'My Name' do not support Network Extensions Capability"**. Apple DTS engineer (Matt Eaton, DTS Engineering, CoreOS) replied: **"Not without code signing with the Network Extension capability tied to your Developer Account."** → Outcome: hard blocked; Apple confirms a paid account is required. https://developer.apple.com/forums/thread/675195

2. **Apple Developer Forums 816045 — "Do I need to request Packet Tunnel Provider entitlement from Apple to get my app working?"** (Feb 2026). A developer assumed a request to Apple was needed for "NetworkExtension → Packet Tunnel Provider entitlement for our Team ID and bundle IDs". Apple DTS (Quinn) replied: **"Does 'everything I'm seeing' refer to stuff from Apple? Or stuff on the 'net? Because if it's advice from Apple then I'd appreciate you replying here with info on where you saw Apple give you that advice, because I'd like to correct it. Sadly, I can't fix the Internet (-:"**, and confirmed **"Correct [1]"** that the Xcode option suffices, with footnote **[1]** requiring **"you're part of a paid developer team"** and **"You're creating a packet tunnel provider."** The developer's own log showed `entitled = 0, hasProviderPermission = 0` and **"Failed to obtain authorization right for 3: no authorization provided"** for the failing configuration. https://developer.apple.com/forums/thread/816045

3. **Apple Developer Forums 816877 — "Request for Guidance on Approval Process for Network Extension Entitlement."** Developer asked how to request the `com.apple.developer.networking.networkextension` entitlement for content filtering. Apple DTS: **"There is no approval process for this. Most NE entitlements, including the one for content filters, are available to all (paid) developers."** plus **"Historically there was an approval process for this but that's not been the case for almost 10 years now."** https://developer.apple.com/forums/thread/816877

4. **Apple Developer Forums 67613 — "Network Extension Framework Entitlements"** (created Nov '16, DTS Engineer, locked sticky). The canonical FAQ. Confirms the Nov 2016 policy change, the app-push-provider and Hotspot Helper exceptions, and gives the profile-dump showing `packet-tunnel-provider` in the entitlement allowlist. Also states it is **"IMPORTANT"** that **"`NEHotspotHelper` is only useful for hotspot integration. There are both technical and business restrictions that prevent it from being used for other tasks…"**. https://developer.apple.com/forums/thread/67613

5. **Apple Developer Forums 784800 — "Mac can't find or register NE App Extension without App Sandbox entitlement"** (May 2025). A packet tunnel extension stopped being registered when a required entitlement was removed: **"Failed to find an app extension with identifier app.acmeVpnM.extension and extension point com.apple.networkextension.packet-tunnel: (null)"** / **"Found 0 registrations for app.acmeVpnM.extension (com.apple.networkextension.packet-tunnel)"**. Apple DTS: **"On macOS, App Sandbox is mandatory: For all Network Extension app extensions."** https://developer.apple.com/forums/thread/784800

6. **Stack Overflow 64859177 — "Xcode Network Extensions Account."** Developer on a *personal team* (and then a university account) could not build Apple's SimpleFirewall sample. Reported errors, verbatim: **"No profiles for 'com.example.apple-samplecode.SimpleFirewall8FTGRDPGFZ' were found"** and **"Personal development teams, including ….., do not support the System Extension and Network Extensions capabilities."** Answer: **"The only way to use NE is a 'developper' account with the membership fees."** https://stackoverflow.com/q/64859177

7. **Stack Overflow 77974220 — "Add Network Extensions capability to iOS app without joining Apple Developer Program?"** The accepted answer, verbatim: **"The free tier 'Apple Developer' cannot add network extensions or personal VPN capabilities. You will need a paid Apple Developer Program membership."** https://stackoverflow.com/q/77974220

8. **Stack Overflow 63476574 — macOS variant of the same question.** Xcode error, verbatim: **"Your development team, 'Potato Dev2', does not support the Network Extensions capability."** Answers: one confirms **"to write macOS software that uses the NetworkExtension APIs, you must be a member of the Apple Developer Program ($100/year)"**; another describes disabling SIP and booting with `amfi_get_out_of_my_way=1` to bypass the check (a system-integrity-disabling workaround, not a supported path). A later comment reports **"Cannot create a Mac App Development provisioning profile for … Personal development teams, including \*\*\*, do not support the System Extension capability."** https://stackoverflow.com/q/63476574

9. **Stack Overflow 73728268 — "Network Extension capability missing in dev portal"** (education/university licence). Developer could not add the Network Extensions capability, substituted Personal VPN, and got runtime failures:
   `Error Domain=NEConfigurationErrorDomain Code=10 "permission denied"` and `Error Domain=NEVPNErrorDomain Code=5 "permission denied"`. https://stackoverflow.com/q/73728268

10. **Stack Overflow 41957328 — "Can't save configuration of NETunnelProviderManager."** `Error Domain=NEVPNErrorDomain Code=5 "permission denied"` on `saveToPreferences`; asker had Personal VPN but not Network Extensions enabled for the App ID. https://stackoverflow.com/q/41957328

11. **Stack Overflow 35325487 — "NEVPNErrorDomain Error 1 when trying to start TunnelProvider network extension."** `Error Domain=NEVPNErrorDomain Code=1 "(null)"` from `startVPNTunnelAndReturnError:`; fixed by calling `loadFromPreferences` before starting. Notably the asker confirms the VPN permission prompt appeared once the correct provisioning profile was used: **"after using the proper provisioning profile I was able to see the popup confirming I want to add a VPN when I run the app, and then it get's added in Settings under VPN."** https://stackoverflow.com/q/35325487

12. **Stack Overflow 79153717 — App Store validation requires the entitlement on both the app and the extension** (see Question 1 for the verbatim error payload). https://stackoverflow.com/q/79153717

**Explicit gap:** although I located threads 816045, 816877, 784800 and 67613 by title via search and then read them successfully in a browser session, **Apple Developer Forums blocks automated/scripted fetching** (bot-verification interstitial, HTTP 403 on mirror hosts, and the forum SPA returns only a shell to text proxies). Content for threads 675195, 816045, 816877, 784800, 806802, 725805 and 67613 was read interactively in a browser and is quoted above. I did **not** find any thread in which a developer ran a `NEPacketTunnelProvider` under a free Personal Team and reported runtime behaviour — consistent with the conclusion that the process cannot be signed or installed in that configuration.

---

# CONFIDENCE SUMMARY

### Question 1 — Entitlement key, type, values
| Claim | Confidence |
|---|---|
| Key is `com.apple.developer.networking.networkextension`, titled "Network Extensions Entitlement" | **HIGH** |
| Type is an array of strings | **HIGH** |
| `packet-tunnel-provider` is an accepted value | **HIGH** |
| Full 12-value list as enumerated | **HIGH** |
| Apple's description of `packet-tunnel-provider` | **HIGH** |
| The **extension** must have the entitlement | **HIGH** |
| The **containing app** must also have it (App Store validation) | **HIGH** |
| The **containing app** must also have it (runtime) | **MEDIUM** — inferred from `nehelper` `entitled`/`hasProviderPermission` logs and WireGuard's structure; no single Apple sentence states it |
| No Apple sentence states "both bundles" explicitly | **HIGH** (negative finding) |

### Question 2 — Personal Team availability
| Claim | Confidence |
|---|---|
| Network extensions is NOT available to the free ("Apple Developer") column | **HIGH** |
| Personal VPN is NOT available to the free column | **HIGH** |
| App groups IS available to the free column | **HIGH** |
| Keychain sharing IS available to the free column | **HIGH** |
| Full 57-row table transcription | **HIGH** |
| The "Apple Developer" column denotes the Personal Team population | **HIGH** |
| The column is literally labelled "Personal Team" | **FALSE** — it is labelled "Apple Developer" |

### Question 3 — Runtime behaviour without the entitlement
| Claim | Confidence |
|---|---|
| `NEVPNError` numeric values 1–6 as listed | **HIGH** (from Apple's shipped SDK header; Apple's web docs confirm names, not numbers) |
| Code 5 is `ConfigurationReadWriteFailed`, **not** `ConfigurationStale` (code 4) | **HIGH** |
| `startTunnel(options:)` is documented to fail with code 1 or 2 | **HIGH** |
| `loadAllFromPreferences` documents no specific error code | **HIGH** (negative finding) |
| `saveToPreferences` fails with `NEVPNErrorDomain` code 5 `"permission denied"` when the Network Extensions entitlement is missing | **MEDIUM** — two independent reports, but both had Personal VPN present and neither was a controlled "no NE entitlement at all" test |
| `NEConfigurationErrorDomain` code 10 `"permission denied"` accompanies it | **MEDIUM** — single report |
| The extension process does **not** launch (not registered) | **MEDIUM** — documented on macOS via `Found 0 registrations`; iOS case inferred by analogy, **not verified** |
| The system computes `entitled` / `hasProviderPermission` and denies when unentitled | **MEDIUM-HIGH** — user-posted `nehelper` logs, not contradicted by Apple |
| `loadAllFromPreferences` returns an empty array / a specific error in this scenario | **UNVERIFIED** |
| Whether the "App would like to add VPN Configurations" alert appears | **UNVERIFIED** (the alert's existence for Personal VPN is HIGH) |
| Whether `startTunnel` throws and with which code in this exact scenario | **UNVERIFIED** |

### Question 4 — Minimum membership and approval
| Claim | Confidence |
|---|---|
| A paid Apple Developer Program membership is required | **HIGH** |
| No special request/approval form is required for Network Extension providers | **HIGH** |
| The change took effect in **Nov 2016**, not 2019 | **HIGH** |
| `NEAppPushProvider` still requires Apple authorisation | **HIGH** |
| `NEHotspotHelper` still requires Apple authorisation | **HIGH** |
| The DPLA §3.3.3(G) clause wording and Apple's reservation of rights | **HIGH** |
| Whether that DPLA clause has been enforced as a separate approval since Nov 2016 | **UNVERIFIED** |

### Question 5 — Free-account limits
| Claim | Confidence |
|---|---|
| Up to 10 App IDs, expiring after 7 days | **HIGH** |
| Up to 3 devices, expiring after 7 days | **HIGH** |
| Up to 3 apps installed per device | **HIGH** |
| Provisioning profiles expire 7 days from issuance | **HIGH** |
| Free accounts lack Certificates, Identifiers & Profiles | **HIGH** |
| The "10 App IDs **per week**" phrasing | **NOT APPLE'S WORDING** — Apple says "up to 10 App IDs, which expire after 7 days" |
| Any limit on the number of app extensions per app | **UNVERIFIED** |

### Question 6 — App extensions under free provisioning
| Claim | Confidence |
|---|---|
| Provisioning profiles cover app extensions as bundles | **HIGH** |
| Xcode reaches profile creation for extension bundles under a Personal Team | **MEDIUM-HIGH** — inferred from the wording of real Xcode errors |
| A Personal Team can build and install an app containing an app extension (e.g. File Provider) | **MEDIUM** — one developer report plus structural inference; no Apple statement |
| A Share Extension or Widget specifically works on a Personal Team | **MEDIUM** — inference; not directly verified |
| A Personal Team can provision a Network Extension (`.appex`) | **FALSE — HIGH confidence it cannot** |

### Question 7 — App Groups on Personal Teams
| Claim | Confidence |
|---|---|
| Apple's capability table marks App groups available to the free tier | **HIGH** |
| Registering an app group requires Account Holder/Admin in Certificates, Identifiers & Profiles | **HIGH** |
| Free accounts have no access to Certificates, Identifiers & Profiles | **HIGH** |
| Apple documents an alternative Xcode path ("create app groups when you enable app groups in Xcode") | **HIGH** |
| Whether that Xcode path actually works under a Personal Team | **UNVERIFIED** |
| The Xcode error "The 'App Groups' feature is only available to users enrolled in the Apple Developer Program" | **UNVERIFIED** — I verified that error's form for Push Notifications but could not find it attested for App Groups |

### Question 8 — Keychain Sharing / default access group
| Claim | Confidence |
|---|---|
| Default keychain access group is `<teamID>.<bundleID>` when no keychain access groups are specified | **HIGH** |
| An app is always a member of at least one group containing only itself | **HIGH** |
| Keychain Sharing capability is available to the free tier | **HIGH** |
| The entitlement key is `keychain-access-groups`, array of strings | **HIGH** |
| A Personal-Team app can read a generic password it stored itself, across re-signs, for the same Apple Account + bundle ID | **MEDIUM** — follows from the documented derivation; no Apple statement about stability across re-signs |
| Enrolling in the paid program later orphans prior keychain items (team ID change) | **UNVERIFIED** |

### Question 9 — Personal VPN vs Network Extensions
| Claim | Confidence |
|---|---|
| They are two distinct entitlements for two distinct APIs | **HIGH** |
| `com.apple.developer.networking.vpn.api` = `[allow-vpn]`, for `NEVPNManager` / built-in IPsec+IKEv2 | **HIGH** |
| Packet tunnel provider's Essentials entitlement is the Network Extensions entitlement | **HIGH** |
| `com.apple.developer.networking.vpn.api` is **not** required for a `NEPacketTunnelProvider` today | **MEDIUM-HIGH** — Apple's Essentials pairing + WireGuard production evidence; no explicit Apple retraction sentence found |
| The 2016–2017 "you need both" advice is stale | **MEDIUM-HIGH** (same basis) |
| Both entitlements are unavailable to free/Personal Teams | **HIGH** |

### Question 10 — Forum / Stack Overflow evidence
| Claim | Confidence |
|---|---|
| All twelve threads/questions listed exist at the cited URLs with the cited content | **HIGH** for Apple forum threads read interactively (675195, 816045, 816877, 784800, 806802, 725805, 67613) and for all Stack Overflow items (retrieved via the Stack Exchange API) |
| Apple DTS's replies as quoted on 675195, 816045, 816877, 67613 | **HIGH** |
| The `nehelper` log excerpt on 816045 | **MEDIUM** — user-posted, not independently reproduced |
| No thread exists showing a free-team `NEPacketTunnelProvider` reaching runtime | **MEDIUM** — a negative finding from my search, not proof of absence |

### Overall headline conclusions
| Claim | Confidence |
|---|---|
| A Personal Team **cannot** provision an app extension requiring `com.apple.developer.networking.networkextension` with `packet-tunnel-provider` | **HIGH** |
| The block occurs at **build/provisioning time**, not runtime | **HIGH** |
| No Apple approval form is needed — the capability is self-service for paid accounts | **HIGH** |
| The relevant policy date is **Nov 2016**, not 2019 | **HIGH** |
| `NEVPNErrorDomain` code 5 is **`configurationReadWriteFailed`**, not `configurationStale` (which is code 4) | **HIGH** |
