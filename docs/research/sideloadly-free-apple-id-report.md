# Sideloadly + Free Apple ID: Signing Pipeline, Entitlements, and Capability Boundaries

**Scope:** Sideloadly (sideloadly.io) as of **v0.60.0** (latest, released 2025-08-01), iOS 17/18/26 era, free Apple ID (no paid Apple Developer Program membership).
**Method:** web search/fetch, direct DOM extraction from Apple's capability table, GitHub issues/source, Reddit via the Exa index (Reddit itself bot-blocks this environment).
**Convention:** every claim carries a confidence label. `UNVERIFIED` means I could not source it — I did not guess.

---

## 1. What Sideloadly actually does when signing with a free Apple ID

**Short answer:** Sideloadly performs the same class of operation as AltStore/SideStore: it logs into Apple with your Apple Account (using **anisette** data to satisfy Apple's device-attestation check), **registers App IDs**, obtains an **iOS development certificate**, fetches **provisioning profiles**, may **mangle the bundle ID**, signs the IPA locally, and installs it over USB/Wi-Fi using libimobiledevice. **Sideloadly is closed-source and publishes no technical description of its pipeline**, so the pipeline is reconstructed from its own error strings, FAQ and changelog — plus the equivalent open-source implementation in AltStore.

**Does it use an anisette server?** Yes, and this is officially documented.

> "We use our server for Anisette data only. This data is only transmitted if using the "**Remote Anisette**" option under Sideloadly's Advanced Options. When using remote anisette, here is the exhaustive list of information our server can see: - Your IP address - Your OS (win32, win64 or macOS) - Sideloadly version"
> — https://sideloadly.io/faq (also https://sideloadly.io/faq.html)

> "Sideloadly no longer requires a Mail Plug-In to obtain the required anisette data. However, the Mail Plug-In option will still be available as a backup."
> — https://sideloadly.io/changelog (v0.50.0)

Local anisette was added in v0.26.0 ("Sideloadly will support 3 different ways to obtain the required data for sideloading: Local, Remote & No Anisette"), and v0.60.0 states "Apple ID login has been significantly improved, resolving Anisette and general authentication issues."

**Does it call Apple's developer API to register an App ID?** Strongly evidenced by Sideloadly's own quota error, and explicit that the quota is Apple's:

> "How do I fix "Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days."? This is a limitation set by Apple on free developer accounts."
> — https://sideloadly.io/faq

> "App ID tracking: Sideloadly will now display the number of available (weekly) App IDs remaining for each Apple ID."
> — https://sideloadly.io/changelog (v0.55.0)

**Certificate generation/management:** evidenced by changelog fixes for certificate-specific errors.

> "Don't crash when trying to revoke oldest certificate" — https://sideloadly.io/changelog (v0.15.9)
> "Fixed "There is no 'ios' certificate with serial number" error" — https://sideloadly.io/changelog (v0.17.2)

**Provisioning profile:** evidenced by the FAQ entry for "A valid provisioning profile for this executable was not found." (https://sideloadly.io/faq), and by "Disabled the removal of profiles before sideloading" (v0.24.0).

**Bundle ID mangling** (free accounts cannot reuse an App Store bundle ID):

> "With the latest iOS versions, Apple has prevented users on free Apple accounts from sideloading apps that have the same bundle ID as an App Store app. As a result, we are forced to set a unique bundle ID, which Game Center does not recognize."
> — https://sideloadly.io/faq
> "Bundle ID mangling will now be disabled if anisette option is unticked" — https://sideloadly.io/changelog (v0.19.0)

**Device communication:** Sideloadly's error messages are literally **libimobiledevice** symbol names — `lockdownd_client_new_with_handshake`, `afc_client_new`, `instproxy_client_new`, `np_client_new`:

> "How do I fix "Call to lockdownd_client_new_with_handshake failed: LOCKDOWN_E_INVALID_HOST_ID" error?" / "Call to afc_file_close failed: AFC_E_MUX_ERROR" / "Call to np_client_new failed: NP_E_CONN_FAILED"
> — https://sideloadly.io/faq
> "FAILED: Call to instproxy_client_new failed: INSTPROXY_E_CONN_FAILED" — user-reported Sideloadly log, https://www.reddit.com/r/sideloadly/comments/1mf7eul/sideloadly_v060_update_advanced_data_protection/

**Signing engine — Sideloadly appears to be zsign-based.** This is a third-party claim, repeated in two independent places in the zsign project, but **not confirmed by sideloadly.io**:

> "Sign the IPA with a zsign-based tool (e.g. Sideloadly, Feather); install on iOS 26.5."
> — https://github.com/zhlynn/zsign/issues/396
> "Concrete repro: Apollo for Reddit's `OpenInUIExtension` share action — broken under Sideloadly/Feather on iOS 26.5, works once the IPA is re-signed with `codesign`."
> — https://github.com/zhlynn/zsign/pull/391

**The open-source equivalent (AltStore) shows what the App-ID/certificate/profile step looks like** — it prepares one profile per bundle, enables the App ID features implied by the app's entitlements, and rewrites Info.plist bundle IDs to match the profile:

> "Every app you sideload with AltStore requires a certain number of "App IDs" to be registered with your Apple ID, which depends on the number of app extensions each app contains. You can only register up to 10 App IDs at a time, but each App ID expires after one week."
> — https://faq.altstore.io/altstore-classic/app-ids

```swift
// AltServer/Devices/ALTDeviceManager+Installation.swift (altstoreio/AltStore)
self.prepareProvisioningProfile(for: application, parentApp: nil, ...)   // main app
for appExtension in application.appExtensions {
    self.prepareProvisioningProfile(for: appExtension, parentApp: application, ...)
    profiles[appExtension.bundleIdentifier] = profile
}
...
let requiredFeatures = app.entitlements.compactMap { (entitlement, value) -> (ALTFeature, Any)? in
    guard let feature = ALTFeature(entitlement: entitlement) else { return nil }
...
guard let profile = profiles[identifier] else { throw ALTError(.missingProvisioningProfile) }
infoDictionary[kCFBundleIdentifierKey as String] = profile.bundleIdentifier
```

**Evidence:**
- No official Sideloadly statement describing the signing pipeline exists — **UNVERIFIED as an official description**; the above is reconstructed from Sideloadly's own error strings/FAQ/changelog plus the AltStore analogue.
- zsign-based: **third-party claim (2 sources), not confirmed by Sideloadly**.
- "Does it handle nested app extensions / plugins?" → see Q2.

---

## 2. App extensions (`PlugIns/*.appex`)

**Does Sideloadly support extension-containing IPAs?** Yes — it handles them by default, and offers *removal* as the fallback. It does **not** document registering a separate App ID per extension, but the class of tool does exactly that, and Sideloadly's own 10-App-ID quota error is consistent with it.

> "Remove Extensions — Remove individual or all app extensions (PlugIns) before install."
> — https://sideloadly.io/ (Features)

> "Added the option to remove App PlugIns before sideloading" — v0.18.0
> "Sideloadly now allows you to select which app extensions/plugins to remove." — v0.42.1
> "Resolved an issue where certain IPAs failed to install due to multiple PlugIns and Extensions." — v0.55.0
> — https://sideloadly.io/changelog

**Separate App IDs / profile inclusion — the mechanism is documented for the tool class (HIGH), and only inferred for Sideloadly (MEDIUM):**

> "Every app you sideload with AltStore requires a certain number of "App IDs" to be registered with your Apple ID, **which depends on the number of app extensions each app contains.**"
> — https://faq.altstore.io/altstore-classic/app-ids

> "The extension-bearing builds (Standard and GLASS) register about 7 App IDs, one per bundled app extension. A free Apple ID can register 10 App IDs per 7 days, so a clean single install fits, but it is easy to exceed if you install under more than one bundle ID, reinstall within the same week, or sideload other extension-bearing apps. If an install fails with an App ID error, use a No Extensions build (1 App ID) or wait for older App IDs to expire."
> — https://freebox.signulous.com/app?id=apollo-reborn

> "App extensions usually have to be removed — widgets, share sheets, keyboards and watch apps will not work. Each would need its own App ID."
> — https://github.com/pwnapplehat/iPASide

> "You may provide multiple provisioning profiles if the application contains nested applications or app extensions, which need their own provisioning profile."
> — fastlane `resign` docs, cited at https://github.com/fastlane/fastlane/issues/7783

**Known failure modes with extension-containing IPAs** (all real, reported):

1. **PackageInspectionFailed** — nested appex missing after signing/refresh:
   > "Installation failed: 0 PackageInspectionFailed (Failed to load Info.plist from bundle at path /private/var/containers/Bundle/Application/.../YouTube.app/PlugIns/NotificationContentExtension.appex; Extra info about ".../Info.plist": Couldn't stat ...: No such file or directory)"
   > — https://github.com/YTLitePlus/YTLitePlus/issues/495 (iOS 18.1.1, iPhone 13 Pro, Sideloadly)
   > "Same issue for me on the latest Sideloadly - 0.55.2. Also with YouTube." — https://www.reddit.com/r/sideloadly/comments/1gwfvzr/youtube_ipa_sideloading_error/

2. **AppexBundleUnknownExtensionPointIdentifier**
   > "Appex bundle at .../YouTube.app/PlugIns/com.google.ios.youtube.ShareExtension.appex with id com.google.ios.youtube.ShareExtension specifies a value (com.apple.share-services) for the NSExtensionPointIdentifier key ... that does not correspond to a known extension point."
   > — https://www.reddit.com/r/sideloadly/comments/1fywv8v/what_am_i_doing_wrong_trying_to_sideload_uyou_ipa/

3. **AppexBundleIDNotPrefixed** — the structural reason bundle-ID mangling is dangerous for extension IPAs:
   > "Appex bundle at ".../Sample.app/PlugIns/OneSignalNotificationServiceExtension.appex" with identifier "com.sample.OneSignalNotificationServiceExtension" does not have expected identifier prefix "com.PT.sample-.""
   > — https://github.com/nowsecure/node-applesign/issues/128

4. **iOS 26 AMFI kill of nested executables** (zsign-derived signers):
   > "On iOS 26, an app signed with zsign launches fine, but any bundled **app extension** (`.appex`) is killed at launch by AMFI: `AMFI: constraint violation ... <AppexName> has entitlements but is not a main binary`"
   > — https://github.com/zhlynn/zsign/issues/396

**Critical official datapoint — the Sideloadly developer's own recommended workaround for extension IPAs is to remove them:**

> "Try enabling the 'Remove PlugIns' option in Sideloadly to see if that helps!"
> — **u/SideloadlyIO** (official account), https://www.reddit.com/r/sideloadly/comments/1fywv8v/what_am_i_doing_wrong_trying_to_sideload_uyou_ipa/

**Evidence:**
- Sideloadly supports/re-signs extensions by default: HIGH (features page + changelog).
- One App ID registered per extension by free-ID sideloaders: HIGH (AltStore docs + independent community docs).
- **Sideloadly specifically** registering one App ID per `.appex`: MEDIUM — inferred, not stated in Sideloadly's docs.

---

## 3. What happens to entitlements a free profile can't support

**What Sideloadly documents:** only that *customising* entitlements is a paid-only feature.

> "Added support for custom app entitlements (Apple Developer Program only); this is a Patreon-exclusive feature."
> — https://sideloadly.io/changelog (v0.60.0) and the official announcement https://www.reddit.com/r/sideloaded/comments/1mf7yi4/sideloadly_v060_update_advanced_data_protection/

**Does it strip the unsupported entitlements before signing?** **UNVERIFIED.** I found no Sideloadly FAQ entry, changelog line, or developer statement describing entitlement stripping. Any answer here would be a guess, so I am not giving one.

**What *is* observable is the outcome.** Both failure modes exist in the wild, and which one you get depends on whether the entitlement survives into the signature:

**(a) Install fails — when the entitlements exceed the profile:**

> "The executable was signed with invalid entitlements. The entitlements specified in your application's Code Signing Entitlements file are invalid, not permitted, or do not match those specified in your provisioning profile. (0xE8008016)."
> — https://stackoverflow.com/questions/48518994/, https://developer.apple.com/forums/thread/78431
> "0xe8008016 (The executable was signed with invalid entitlements.)" — https://github.com/SideStore/SideStore/issues/782
> "entitlement ' ' has value not permitted by provisioning profile ' '" — https://github.com/nowsecure/node-applesign/issues/128

**(b) Installs and launches, but the feature silently does not work — this is the common case.** iOS enforces the entitlement at *runtime*, so a force-signed app installs and then fails inside the feature:

> "When I try to sideload Orbot, everything works fine, but the Network Extension (aka. "VPN") cannot be installed, which is the main purpose of this app. When I inspect the App IDs created by AltStore on https://developer.apple.com, I see, that "Associated Domains" and "Network Extensions" capabilities are missing."
> — https://github.com/altstoreio/AltStore/issues/1091

> "On a build sideloaded with a free Apple ID (no paid Apple Developer team), opening Settings → Notifications pops this alert and aborts the notifications flow: **Error Loading Notifications** ... Error log: `no valid "aps-environment" entitlement string found for application` ... APNs registration requires the `aps-environment` entitlement, which Apple only issues to a paid Apple Developer team and bakes in at signing time. A free-account sideload can never obtain it at runtime, so iOS calls `-application:didFailToRegisterForRemoteNotificationsWithError:` with the permanent `NSCocoaErrorDomain` code `3000`."
> — https://github.com/Apollo-Reborn/Apollo-Reborn/pull/492

**Why (b) happens rather than a clean error:** signing tools bypass Xcode's pre-flight entitlement check, but iOS still refuses to honour the entitlement.

> "You will need to bypass Xcode when code signing and use the `codesign` command directly because Xcode performs the provisioning profile entitlements check... codesign itself does not perform this check."
> — pmdj, https://stackoverflow.com/questions/63476574/ (6 upvotes; this is exactly the sideloading situation)

**Does it warn?** Sideloadly's installation logs are its warning surface ("Improved installation logs for greater clarity", v0.55.0) — **UNVERIFIED** whether any specific entitlement warning is emitted.

**Evidence:**
- Sideloadly strips entitlements: **UNVERIFIED — no source.**
- Sideloadly warns about stripped entitlements: **UNVERIFIED — no source.**
- Outcome is "installs + feature fails" or "install fails with 0xE8008016": HIGH (multiple independent reports).

---

## 4. Documented limits of Sideloadly + free Apple ID

| Limit | Value | Confidence |
|---|---|---|
| Profile/app validity | **7 days** | HIGH |
| Apps installed simultaneously | **3 per device** | HIGH |
| App IDs registrable | **10 per 7 days** | HIGH |
| Devices registrable | **3 per 7 days** | HIGH (Apple) |
| App Groups | **Supported** on free tier per Apple's table | HIGH (Apple doc) / MEDIUM (in practice) |
| Push notifications | **Not available** | HIGH |
| Network Extension / VPN | **Not available** | HIGH |
| In-App Purchases | **Do not work** | HIGH |

**Sideloadly's own FAQ:**

> "A normal & free Apple Developer account only allows the app to function for 7 days. After 7 days you can sideload it again using the same Apple ID, just make sure your progress is backed up. Apps signed with a paid Apple Developer Account can last up to 1 year."
> "On iOS 7, 8, 9, you can sideload unlimited apps. However, on iOS 10, 11, 12, 13, 14, 15, 16 and higher, a free Apple Developer account is limited to 3 sideloaded apps. A paid Apple Developer Account has no such limit."
> "Unfortunately, no. Apple prevents In-App Purchases from working on sideloaded/enterprise installed apps."
> "App-specific passwords partially works via Sideloadly. App-specific password can only work if you are using a paid Apple Developer ID with anisette option disabled."
> — https://sideloadly.io/faq

**Re-signing:** automated. "Background daemon automatically re-signs your apps every few days to prevent them from expiring." / "Sideloadly includes an auto-refresh daemon that runs in the background and automatically re-signs your sideloaded apps before they expire." (https://sideloadly.io/; requires Wi-Fi sideloading or USB per the FAQ).

**Apple's authoritative free-tier (Personal Team) limits:**

> "If your account is not associated with a developer program membership, Xcode will indicate it's a Personal Team. Your account's App IDs, devices, certificates, and provisioning profiles are managed directly in Xcode, and you'll be required to reprovision your apps to a device periodically.
> - You can register up to 10 App IDs, which expire after 7 days.
> - You can register up to 3 devices, which expire after 7 days.
> - You can install up to 3 apps per device. Provisioning profiles that enable apps to be installed on a device will expire 7 days from issuance. You'll need to rebuild and reinstall your app to your device after expiration."
> — https://developer.apple.com/help/account/basics/about-your-developer-account/

**Apple's capability table — I extracted this directly from the page DOM** (`<figure class="icon icon-checksolid" alt="yes">` = supported). The **"Apple Developer" column is the free tier**:

> "**Apple Developer:** Apple Account holders who have agreed to the Apple Developer Agreement to access certain resources on the Apple Developer website. No cost is associated with this agreement and developers can't distribute apps."
> — https://developer.apple.com/help/account/reference/supported-capabilities-ios/

| Capability | ADP (paid) | ADEP | **Apple Developer (free)** |
|---|---|---|---|
| **App groups** | ✔ | ✔ | **✔** |
| Background modes | ✔ | ✔ | **✔** |
| Data protection | ✔ | ✔ | **✔** |
| HealthKit | ✔ | ✔ | **✔** |
| HomeKit | ✔ | ✔ | **✔** |
| Inter-App Audio | ✔ | ✔ | **✔** |
| Keychain sharing | ✔ | ✔ | **✔** |
| Maps | ✔ | ✔ | **✔** |
| Wireless Accessory Configuration | ✔ | ✔ | **✔** |
| **Network extensions** | ✔ | ✔ | **(blank — unavailable)** |
| **Personal VPN** | ✔ | ✔ | **(blank — unavailable)** |
| **Push notifications** | ✔ | ✔ | **(blank — unavailable)** |
| iCloud (all three) | ✔ | ✔ | (blank) |
| Associated domains | ✔ | ✔ | (blank) |
| Sign in with Apple | ✔ | ✔ | (blank) |
| App Attest | ✔ | ✔ | (blank) |
| Game Center | ✔ | — | (blank) |

*(Independent corroboration of the two key rows: a screenshot of the same table, read verbatim, confirms Network extensions and Personal VPN are blank in the free column — https://stackoverflow.com/questions/77974220/*)

**Push notifications on free accounts — confirmed by Xcode's refusal:**
> "Your development team, " ACCOUNT NAME", does not support the Push Notifications capability." — https://stackoverflow.com/questions/55828837/

**App Groups — an important caveat:** Apple's table says App Groups *are* available to free accounts, but practical reports are mixed, and AltStore's own error codes include app-group-specific failures:
> "(3014) The provided app group is invalid." / "(3015) App group does not exist." — https://faq.altstore.io/altstore-classic/error-codes
One commercial signing service documents that App Groups is "supported on certificate level but NOT enabled on provisioning level" (https://iosrocket.com/pages/enabled-certificate-entitlements) — a commercial, non-authoritative source. **Practical free-account App Groups behaviour: MEDIUM/UNVERIFIED.**

---

## 5. Network Extension / VPN support, and paid-certificate signing

**Does Sideloadly document any support for installing an app with Network Extension / VPN entitlements?** **No.** There is no NE/VPN statement anywhere in Sideloadly's Features page, FAQ, or changelog. **UNVERIFIED as a feature.** Sideloadly's only VPN-adjacent FAQ entry is about *network configuration*, not entitlements:

> (third-party mirror of the Sideloadly FAQ) "Can I use Sideloadly with a specific set of rules, like a proxy or VPN? A: Sideloadly does not currently support proxy or VPN configurations."
> — https://github.com/SideloadlyiOS/Sideloadly-Download — **this entry is NOT present on sideloadly.io; treat as UNVERIFIED.**

**Is a paid account required?** Per Apple's table, yes for the capability itself — Network extensions and Personal VPN are blank for the free tier. The AltStore maintainer states the constraint directly:

> "'free' Apple Developers can't use the Networking Extension - but that's no reason to disallow it for Paid ADPs."
> — AltStore maintainer (lonkelle), https://github.com/altstoreio/AltStore/issues/1091#issuecomment-1364602802

> "The free tier "Apple Developer" cannot add network extensions or personal VPN capabilities. You will need a paid Apple Developer Program membership."
> — Paulw11, https://stackoverflow.com/questions/77974220/

> "Sideloading doesn't work either, as free accounts are not eligible for this entitlement."
> — https://github.com/PlayCover/PlayCover/issues/1241

**Does Sideloadly support a paid developer certificate + custom provisioning profile?** Paid **Apple ID sign-in** is supported; **custom `.p12` + `.mobileprovision` is not.**

> "Better support for Apple IDs enrolled in the Apple Developer Program (paid Apple IDs). Now you can sideload just as you would with a normal Apple ID and Sideloadly will take care of the rest!"
> — https://sideloadly.io/changelog (v0.40.3)

**No `--p12` / `--prov` equivalents exist, and the official account confirmed the feature request is unimplemented:**

> Q: "I have my cert that should be valid for a year time, is there any possibility for sideloadly to use that one instead alongside mp.mobileprovision?"
> **u/SideloadlyIO** (2024-08-09): "This is not currently supported but it's a feature we'd like to add."
> — https://www.reddit.com/r/sideloadly/comments/1elktyn/can_i_specify_my_own_p12_cert_in_sideloadly/

> **u/SideloadlyIO** (2022-11-01): "Hello! This is something we may introduce at a later date."
> — https://www.reddit.com/r/sideloadly/comments/yjfqn7/is_there_a_way_to_use_custom_certificate_and/

(The user in that 2022 thread asserts "By default sideloadly use our own iOS Developper certificate" — that is a **user's** wording, not Sideloadly's; treat as UNVERIFIED.)

**Install modes** — the GUI offers four; only "Apple ID sideload" is documented in detail:
> "Multiple Install Modes — Apple ID sideload, normal install, ad-hoc sign, and export tweaked IPA. Each option explained on hover."
> — https://sideloadly.io/ ; "New install options: Apple ID Sideload, Normal Install, Ad-hoc Sign & Install." — v0.21

**What "Normal Install" means is UNVERIFIED** — Sideloadly documents it only as a hover tooltip. It is *not* documented as "supply your own certificate + profile".

**The only entitlement control is paid-only and Patreon-gated:**
> "Added support for custom app entitlements (Apple Developer Program only); this is a Patreon-exclusive feature." — v0.60.0

A third-party project states the practical conclusion bluntly:
> "CB Pro Proxy requires **Network Extension entitlements** to create VPN connections. These entitlements cannot be added with: - ❌ Free Apple ID (AltStore/Sideloadly) - ❌ Standard jailbreak with ideviceinstaller - ❌ Unsigned IPA installation methods"
> — https://raw.githubusercontent.com/coolbirdzik/CB-Pro-Proxy/main/docs/TROLLSTORE_INSTALLATION.md *(third-party, unaffiliated; its technical vocabulary is loose — treat as indicative, not authoritative)*

---

## 6. Reports of running a VPN / Network Extension app sideloaded with a free Apple ID

**Outcome across every concrete report found: it installs and launches, but the VPN tunnel never works.** No report was found of a free-ID sideload where the tunnel actually connected.

> "I have a iOS app that creates a VPN connection ... The app opens normally in PlayCover, but fails when creating the VPN connection. Log shows that the app uses the NEVPNManager API and got Permission Denied when calling saveToPreferences(). ... **Sideloading doesn't work either, as free accounts are not eligible for this entitlement.**"
> — https://github.com/PlayCover/PlayCover/issues/1241 (open since 2023-12-01)

> "When I try to sideload Orbot, everything works fine, but the Network Extension (aka. "VPN") cannot be installed, which is the main purpose of this app."
> — https://github.com/altstoreio/AltStore/issues/1091 (open)

> "Since iOS15 it is impossible to properly sign VPN app with Sideloadly!!!! ... Before iOS15, you had to login into your developer account via www, find the bundle id of your app in „Identifiers" and enabling two following entitlements - Network Extensions and vpn Tunnel. Then sign with Sideloadly again. Voila. Since iOS15 the situation has changed. Repeating above procedure „almost" work - all seems to be fine and you are even able to add new VPN profile… but it just won't start and crash log will say that the VPN plugin binary executable is not signed. The only way for me to get VPN apps signed as needed was to generate a new Apple Developer Certificate..."
> — https://www.reddit.com/r/sideloaded/comments/wnhnet/vpn_profile/ (2022)

**Note the crucial detail in that last quote:** the user *was able to add a VPN profile* — the configuration appeared — but the tunnel would not start. That is the signature failure mode.

> Q: "Do sideloaded vpn apps work? I tried sideloading vpn apps to Live container or even the main Altstore but they don't work"
> A: "You need the VPN entitlement which is only on paid certificates or paid Apple developer accounts"
> — https://www.reddit.com/r/sideloaded/comments/1labq3p/vpn_apps/ (2025-06-13)

> Flutter/WireGuard real-device console: `PlatformException(-4, Optional(Error Domain=NEVPNErrorDomain Code=5 "IPC failed" ...), IPC failed, null)`
> — https://github.com/Caqil/wireguard_flutter/issues/12 ("Cant connect VPN in IOS", multiple users, tunnel never connects)

**Evidence quality note:** Reddit is bot-blocked from this environment; the Reddit quotes above were retrieved via the Exa index and are attributed to their permalinks. r/sideloadly as a whole was searched but not exhaustively enumerable — **UNVERIFIED as exhaustive.**

---

## 7. Sideloadly vs AltStore/AltServer vs TrollStore on entitlements

**The entitlement model, stated precisely:**

> "On Apple systems, every entitlement has to be either signed by Apple or authorized by a provisioning profile signed by a developer certificate. TrollStore uses a CoreTrust bug to "fake" an Apple root certificate so that the system thinks the app is signed by Apple. It is almost like jailbreaking, just not as invasive. The problem with provisioning profile is that many entitlements require paid developer accounts. If you have one, you may be able to sign apps with many special entitlements, but still not arbitrary ones like TrollStore."
> — https://github.com/PlayCover/PlayCover/issues/1241#issuecomment-1899408999

| | Sideloadly (free ID) | AltStore Classic (free ID) | TrollStore |
|---|---|---|---|
| Entitlement source | Apple-issued profile from your free Apple ID | Apple-issued profile from your free Apple ID | Fake root certificate (no profile) |
| Arbitrary entitlements | No | No | **Yes** (documented) |
| Network Extension / VPN | No | No | **Third-party documented, not officially** |
| Expiry | 7 days (auto-refresh) | 7 days | Permanent ("permasigned") |
| App limit | 3 | 3 | No documented limit |
| iOS range | iOS 7 – 26+ | iOS 12+ (AltStore Classic) | **iOS 14.0b2 – 16.6.1, 16.7 RC, 17.0 only** |

**AltStore's own docs concede the capability gap on the free-ID path:**
> "| Full iOS App Capabilities | AltStore PAL ✅ | AltStore Classic ❌ |" / "| Apps Expire | ❌ | ✅ (7 days) |"
> — https://faq.altstore.io/llms-full.txt

**TrollStore's documented arbitrary-entitlement capability:**
> "TrollStore is a permasigned jailed app that can permanently install any IPA you open in it."
> "It works because of an AMFI/CoreTrust bug where iOS does not correctly verify code signatures of binaries in which there are multiple signers."
> "The binaries inside an IPA can have arbitrary entitlements, fakesign them with ldid and the entitlements you want (`ldid -S<path/to/entitlements.plist> <path/to/binary>`) and TrollStore will preserve the entitlements when resigning them with the fake root certificate on installation."
> — https://github.com/opa334/TrollStore/blob/main/README.md

**Vulnerable iOS versions — and why this matters here:**
> "Supported versions: 14.0 beta 2 - 16.6.1, 16.7 RC (20H18), 17.0"
> "16.7.x (excluding 16.7 RC) and 17.0.1+ will NEVER be supported (unless a third CoreTrust bug is discovered, which is unlikely)."
> — https://github.com/opa334/TrollStore/blob/main/README.md

> "If your device is on iOS 14.0 *beta 1* or earlier, is running iOS 16.7.x (excluding 16.7 RC (20H18)), or is running iOS 17.0.1 or newer, it will **never** be supported by TrollStore."
> — https://ios.cfw.guide/installing-trollstore/

> "| 17.0.1 and later | Not Applicable | Unsupported |" — https://ios.cfw.guide/installing-trollstore/

**⚠️ This is decisive for the stated context (iOS 17/18):** TrollStore's jailed range ends at **iOS 17.0**. **All of iOS 17.1+, all of iOS 18, and iOS 26 are unsupported.** So for a modern device, TrollStore is not an available answer to the entitlement problem. (TrollStore **Lite** covers 14.0–26.0.1 but is **jailbreak-only** — "TrollStore for jailbroken iOS ... Jailbreak Required", https://havoc.app/package/trollstorelite.)

**TrollStore's documented entitlement limits** (it is not unlimited):
> "iOS 15 on A12+ has banned the following three entitlements related to running unsigned code, these are impossible to get without a PPL bypass, apps signed with them will crash on launch." — `com.apple.private.cs.debugger`, `dynamic-codesigning`, `com.apple.private.skip-library-validation`
> "Things that are not possible using TrollStore: - Getting proper platformization ... - Spawning a launch daemon ... - Injecting a tweak into a system process"
> — https://github.com/opa334/TrollStore/blob/main/README.md

**Was Network Extension under TrollStore ever officially confirmed?** **No.** No official TrollStore documentation names `com.apple.developer.networking.networkextension` or the VPN entitlement. The strongest evidence is third-party:
> "On every push to `main`, the repository updates a credentials-free nightly Release IPA for TrollStore. The app and its extensions are ad-hoc signed with their required Network Extension and App Group entitlements."
> — https://raw.githubusercontent.com/EasyTier/EasyTier-iOS/main/README.md (with a matching `packet-tunnel-provider` entitlements file in-repo)

`com.apple.developer.networking.vpn.api` (Personal VPN) under TrollStore: **UNVERIFIED — no source found at all.**

*(No exploitation instructions are provided here by design; the above is limited to publicly documented capability boundaries and version ranges.)*

---

## 8. What the user actually sees

**Two different things live in `Settings > General > VPN & Device Management`, and a sideloaded VPN app interacts with both:**

1. **The "Developer App" trust entry** created by sideloading — this is what Sideloadly's own FAQ tells you to tap:
> "Go to **Settings > General > Profiles/VPN & Device Management** and once there, tap on the email you used to sideload, then trust it." — https://sideloadly.io/faq
> "Navigate to 'General', and then 'VPN & Device Management'. Under the "Developer App" section, select the option named after your Apple Account." — https://docs.sidestore.io/docs/installation/install

2. **A "DEVICE VPN" row** — only if the app successfully saved a tunnel configuration.

**What happens when the VPN configuration IS created but the entitlement is not honoured** — this is the key user-visible outcome. A user-visible screenshot from a real device, read verbatim:

> **VPN Status — Not Connected** *(toggle greyed out)*
> "**"AdhocVPN" must be updated by the developer before "Wireguard" can be connected.**"
> **DEVICE VPN**
> ✓ Wireguard
> **AdhocVPN - Update Required** *(in red)*
> "Add VPN Configuration…"
> "VPNs can be set up to control the routing of certain network traffic. About VPNs & Privacy..."
> — screenshot attached to https://stackoverflow.com/questions/78412875/

So the user sees the VPN entry **present but permanently unusable**, with a system message blaming the developer — not a clean "missing entitlement" error.

**When the configuration cannot be created at all**, `NETunnelProviderManager.saveToPreferences` fails with a **generic** error that never mentions entitlements:

> `Error Domain=NEVPNErrorDomain Code=5 "permission denied"` — https://stackoverflow.com/questions/41957328/cant-save-configuration-of-netunnelprovidermanager
> `Error Domain=NEVPNErrorDomain Code=5 "IPC failed"` — https://github.com/Caqil/wireguard_flutter/issues/12
> "Sounds like your app is not capable (doesn't have permission) for reading or writing the Network Extension preferences." — https://stackoverflow.com/questions/41957328/

**Important honesty note:** the strings "Missing entitlement", "No VPN profile", and "Failed to save configuration" do **not** appear anywhere as literal iOS Network Extension error text — they were searched for and are **UNVERIFIED**; do not quote them.

**Normally the developer-trust entry is visible after sideloading** — its *absence* is a reported anomaly:
> "After updating to ios 26 beta 2/3, my email no longer shows up in vpn, dns, & device management after sideloading the apps. how do I fix this?"
> — https://www.reddit.com/r/sideloadly/comments/1mf7eul/sideloadly_v060_update_advanced_data_protection/

---

## CONFIDENCE SUMMARY

### HIGH
- Sideloadly uses an anisette server (remote and local); official FAQ + changelog.
- Sideloadly registers App IDs against Apple's per-Apple-ID quota (10 / 7 days); official FAQ + v0.55.0 App-ID tracking.
- Sideloadly obtains an iOS development certificate and provisioning profiles; evidenced by its own certificate/profile error fixes.
- Sideloadly performs bundle-ID mangling on free accounts; official FAQ.
- Sideloadly uses libimobiledevice for device I/O; its error strings are libimobiledevice symbols.
- Free Apple ID limits: 7-day profiles, 3 apps/device, 10 App IDs/7 days, 3 devices/7 days; Sideloadly FAQ + Apple official docs.
- Apple's capability table gives the free "Apple Developer" tier: **Network extensions, Personal VPN, Push notifications, iCloud, Associated domains, Sign in with Apple are all unavailable**; App groups, Background modes, Data protection, HealthKit, HomeKit, Keychain sharing, Maps, Inter-App Audio are available. Extracted directly from page DOM.
- Push notifications do not work on free-account sideloads (missing `aps-environment`).
- Network Extension / VPN does not work with a free Apple ID; confirmed by AltStore maintainer, Apple capability table, and multiple user reports.
- Sideloadly supports extension-containing IPAs and offers extension removal as the mitigation; official dev recommends removal when installs fail.
- Failure mode for unsupported entitlements is either install failure (0xE8008016) or install-and-launch with a non-functional feature.
- TrollStore's supported jailed range is iOS 14.0b2–16.6.1, 16.7 RC, 17.0; **17.0.1+ and all of iOS 18/26 are permanently unsupported**.
- TrollStore documents "arbitrary entitlements" and preserves them on re-sign; 3 banned entitlements; no 7-day expiry ("permasigned").
- Custom `.p12` + `.mobileprovision` is not supported by Sideloadly (official dev statement, 2024).
- Custom entitlements in Sideloadly are paid-account-only and Patreon-gated (v0.60.0).
- iOS surfaces the problem as a generic `NEVPNErrorDomain` error and/or a "must be updated by the developer" VPN row — never a descriptive entitlement error.

### MEDIUM
- Sideloadly's signing engine is zsign — two third-party zsign-project references name it, but Sideloadly never confirms it.
- Sideloadly specifically registers one App ID per nested `.appex` — the class of tool demonstrably does (AltStore docs + source), and Sideloadly's quota errors are consistent, but Sideloadly's own docs never say so.
- App Groups actually working on a free account in practice — Apple's table says yes, but practical reports are mixed and app-group-specific error codes exist.
- The precise reason extension IPAs break under Sideloadly (bundle-ID mangling vs. per-appex profile handling vs. iOS 26 AMFI) — the mechanisms are each documented, but not attributed to Sideloadly by Sideloadly.
- The "proxy or VPN configurations" FAQ entry exists only on a third-party mirror, not on sideloadly.io.

### LOW
- What Sideloadly's "Normal Install" mode actually does — documented only as a hover tooltip.
- Whether Sideloadly emits any warning when an entitlement is dropped.

### UNVERIFIED (explicitly not sourced — do not treat as fact)
- **Whether Sideloadly strips unsupported entitlements from the binary before signing — no source found.**
- Whether Sideloadly warns the user when it does so.
- Any official Sideloadly statement on Network Extension / VPN entitlement handling.
- Official TrollStore confirmation that `com.apple.developer.networking.networkextension` works under TrollStore.
- Anything at all about `com.apple.developer.networking.vpn.api` (Personal VPN) under TrollStore.
- An explicit "no 7-day expiry" sentence in TrollStore's own docs (it says "permanent"/"permasigned" only).
- Official enumeration of entitlements that fail under TrollStore due to provisioning-profile/team-ID/server-side requirements.
- The error strings "Missing entitlement", "No VPN profile", "Failed to save configuration" as literal iOS NE error text.
- Exhaustive coverage of r/sideloadly — Reddit is bot-blocked from this environment; Reddit evidence came via the Exa index.
