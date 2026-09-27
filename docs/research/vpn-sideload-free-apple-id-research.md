# Sideloading a VPN / Network Extension app on a non-jailbroken iPhone with a FREE Apple ID

**Research date:** 2026-09-27
**Scope:** community reports (2022–2026) + Apple first-party documentation, with verbatim quotes and URLs.

## Methodology / access limitations (read this first)

Three source classes were **partially or wholly inaccessible** from this environment. Where I could not verify something, I say so rather than reconstructing it:

| Source | Status | Impact |
|---|---|---|
| Reddit (`reddit.com`, `old.reddit.com`, `r/sideloadly`, `r/AltStore`, `r/sideloaded`, `r/jailbreak`) | **BLOCKED.** HTTP 403 "You've been blocked by network security" from the JSON API, from `old.reddit.com`, via a `r.jina.ai` proxy, via a `redlib` mirror (Anubis proof-of-work wall), **and via a real headless browser (Playwright)**. | **No Reddit quotes appear in this report.** Point 1's Reddit component is UNVERIFIED. |
| `developer.apple.com/forums/thread/*` direct fetch | **BLOCKED** by a "Security verification in progress" bot wall. `r.jina.ai` returns only the JS nav shell (thread body is client-rendered). | One thread (675195) was recovered via the Wayback Machine. Two others (750719, 816045) have **no archive** (`web.archive.org/cdx` returns `[]` for both) and could not be read. |
| Stack Overflow HTML pages | **BLOCKED** (Cloudflare 403). | Worked around successfully using the **Stack Exchange API** (`api.stackexchange.com/2.3/...`), which returns question/answer bodies verbatim. |

Everything quoted below was read by me from the source at the cited URL, except where explicitly flagged.

---

## 1. Community reports of sideloading a VPN / Network Extension app with a FREE Apple ID

**Short answer: yes, there are multiple independent reports, and they agree.** The app typically installs and launches, but the VPN/Network Extension component does **not** become functional. In the best-documented case the app's own code path fails at `saveToPreferences()` with "Permission Denied"; in others the tunnel entry appears in Settings but is permanently marked "Update Required" and can never connect.

### Evidence

- **PlayCover issue #1241 — "[Feature]: Support apps that create VPN connections"** (opened 2023-12-01, still open). This is the single clearest report. The reporter is running an iOS app on macOS via PlayCover, and the failure mode is identical to the entitlement problem on iOS:

  > "I have a iOS app that creates a VPN connection that I would like to run on macOS. The app opens normally in PlayCover, but fails when creating the VPN connection. Log shows that the app uses the [NEVPNManager](https://developer.apple.com/documentation/networkextension/nevpnmanager/) API and got Permission Denied when calling [saveToPreferences()](https://developer.apple.com/documentation/networkextension/nevpnmanager/1405985-savetopreferences). Upon research, it seems that NEVPNManager requires a special [entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_developer_networking_vpn_api) that is not available to non App Store apps (not sure about this part)."

  And, decisively for this research question, under "Anything else?":

  > "Sideloading doesn't work either, as free accounts are not eligible for this entitlement."

  <https://github.com/PlayCover/PlayCover/issues/1241>

- **AltStore issue #1091 — "Created App ID for sideloaded app doesn't contain correct capabilities"** (opened 2022-12-07, still open). This is a real-world free-Apple-ID sideload of a VPN app (Orbot, which is Tor over a `packet-tunnel-provider`):

  > "When I try to sideload [Orbot](https://github.com/guardianproject/orbot-apple/releases/tag/v1.4.1), everything works fine, but the Network Extension (aka. "VPN") cannot be installed, which is the main purpose of this app."
  >
  > "When I inspect the App IDs created by AltStore on https://developer.apple.com, I see, that "Associated Domains" and "Network Extensions" capabilities are missing. (I can't see any created profiles, interestingly enough.)"
  >
  > "Activating these capabilities and refreshing in AltStore does nothing."

  <https://github.com/altstoreio/AltStore/issues/1091>

- **AltStore maintainer confirming this is a known, accepted limitation** — issue #1091 comment by `lonkelle` (`author_association: "MEMBER"`), 2022-12-25:

  > "@tladesignz I'll work on this, it's a known issue since "free" Apple Developers can't use the Networking Extension - but that's no reason to disallow it for Paid ADPs. I'll update this issue when I fix it."

  <https://github.com/altstoreio/AltStore/issues/1091#issuecomment-1364602802>

- **Stack Overflow #77974220 — "Add Network Extensions capability to iOS app without joining Apple Developer Program?"** (asked 2024-02-10). The asker is trying to build a personal-use VPN app. The accepted answer (Paulw11, 116k rep, Mobile Development collective) states:

  > "The first column in the table is the (paid) Apple Developer Program. The middle column is the Apple Enterprise Developer Program. The last column is the (free) Apple Developer level:"
  >
  > "The free tier "Apple Developer" cannot add network extensions or personal VPN capabilities."
  >
  > "You will need a paid Apple Developer Program membership."

  The answer attaches a screenshot of Apple's own capable table — verified separately in Point 5 below.

  <https://stackoverflow.com/questions/77974220/add-network-extensions-capability-to-ios-app-without-joining-apple-developer-program>

- **Stack Overflow #78412875 — "VPN: Before "VpnName" may be linked, "AppName" must be modified by the developer"** (asked 2024-05-01, tags `ios swift vpn wireguard`). A developer building a WireGuard-based app reports that after configuring targets, Network Extension and App Groups, the app installs but iOS Settings refuses to let the tunnel connect; the wireguard profile is stuck in an "Update Required" state (see Point 2 for the verbatim on-screen text and a transcription of the attached screenshot).

  <https://stackoverflow.com/questions/78412875/>

- **`Caqil/wireguard_flutter` issue #12 — "Cant connect VPN in IOS"**. Multiple users of a Flutter WireGuard/NetworkExtension wrapper report the tunnel never connects on iOS even when it works on Android; one user with a *paid* developer account still hits it. Verbatim user reports:

  > "I am using the **example code** you provided but still can't run it on **IOS**, I get an error on the profile saying "**Update Required**"." (2024-01-22)

  > "The same problem I am using IOS 17, I get an error on the profile saying "Update Required"." (2024-02-05)

  > "I am using IOS 15.8, getting same error." (2024-02-06)

  Note: this thread's root cause turned out to be a `providerBundleIdentifier` mismatch, **not** the entitlement — I include it because it is the most common false-positive when researching this topic, and because its error string (see Point 2) is one people actually see.

  <https://github.com/Caqil/wireguard_flutter/issues/12>

- **SideStore issue #620 — "[BUG] VPN no longer works, so this has essentially become just like AltStore"** (2024-05-10 → last comment 2025-05-12). **Caveat: this is NOT about a sideloaded third-party VPN app.** It is about SideStore's *own* WireGuard/StosVPN loopback tunnel used for on-device refresh. I include it only because it is frequently mis-cited as evidence about sideloaded VPN apps. The user-visible failure is:

  > "Despite having Wireguard enabled and having set up SideStore's VPN, when trying to refresh or sideload more .ipa's, the app fails with:
  > ```
  > Unable to connect to the device, make sure Wireguard is enabled and you're connected to WiFi
  > ```"

  and the still-open conclusion (2025-05-12):

  > "This is still an issue, whether I use WireGuard or StosVPN. People need to saying the fix is to reset the pairing file - that doesn't fix anything, it just gets you another week where the VPN refresh still won't work. With this bug Sidestore is just a tethered install that pretends to be untethered."

  <https://github.com/SideStore/SideStore/issues/620>

### UNVERIFIED

- **No Reddit evidence.** I could not read any Reddit thread (`r/sideloadly`, `r/AltStore`, `r/sideloaded`, `r/jailbreak`) — see access limitations above. I am **not** asserting what Reddit users say.
- I found **no** report of a free-Apple-ID sideload of **Tailscale** or **sing-box** specifically. Tailscale ships from the App Store and its iOS client is not a common sideload target; sing-box is normally distributed via TestFlight/App Store. Treat those two as **UNVERIFIED**.
- I found **no** first-hand report of a free-Apple-ID sideload where the VPN tunnel **did** work. Every concrete report found says it did not.

---

## 2. Exact error strings and user-visible behaviour

### 2a. Verbatim error strings (all confirmed read from source)

- **`NEVPNErrorDomain` error 2 — the generic runtime failure.** Stack Overflow #46621292, "NEVPNErrorDomain error 2" (asked 2017, still the canonical hit; tags `vpn packet tunnel networkextension`). The asker's own log output, quoted in their question:

  > "I want to develop VPN on iOS By PacketTunnel,But when I run this code ,it will return a error message  "The operation couldn't be completed. (NEVPNErrorDomain error 2.)". This error code can't be found,Does any one know this reason?"

  The highest-voted answer (score 4) attributes it to the VPN configuration not being enabled before saving:

  > "You need to enable manager before start tunnel. I recommend that you add code like this before saveToPreferences."
  > `//Noteice this line` / `man.enabled = YES;`

  **Caveat on the code mapping:** Apple's `NEVPNError.Code` page documents six cases but **does not print the raw integer values**. The community fix above is consistent with raw value 2 = `configurationDisabled`, but I did **not** find an Apple page that states `2 == configurationDisabled`. Treat that specific numeric mapping as **inferred, not verified**.

  <https://stackoverflow.com/questions/46621292/nevpnerrordomain-error-2>

- **`NEVPNErrorDomain Code=5 "IPC failed"` — verbatim, from a real device.** `Caqil/wireguard_flutter` issue #12, comment 2024-10-08, pasted Flutter console output:

  > ```
  > flutter: status changed VpnStage.disconnected
  > flutter: failed to initialize: PlatformException(-4, Optional(Error Domain=NEVPNErrorDomain Code=5 "IPC failed" UserInfo={NSLocalizedDescription=IPC failed}), IPC failed, null)
  > ```

  <https://github.com/Caqil/wireguard_flutter/issues/12#issuecomment-2400844280>

- **"Permission Denied" from `saveToPreferences()` — verbatim.** PlayCover #1241, quoted in full in Point 1 above: *"got Permission Denied when calling saveToPreferences()"*.

- **Xcode code-signing refusal — verbatim, from Apple DTS.** Apple Developer Forums thread **675195, "Network Extension Capability"** (recovered via Wayback; see Point 4 for full quotes). The developer reports:

  > "when i run the project on device Xcode returns this error "Personal development teams , including 'My Name' do not support Network Extensions Capability""

  Note the exact wording and spacing as archived: `Personal development teams , including 'My Name' do not support Network Extensions Capability`.

- **The analogous System Extension string** (macOS, same mechanism, shows the template). Stack Overflow #63476574, comment by `user27269925`, 2024-09:

  > ```
  > Cannot create a Mac App Development provisioning profile for "com.example.ExampleCam.ExampleCam". Personal development teams, including ***, do not support the System Extension capability.
  > ```

- **Push Notifications analogue for free accounts** (relevant because it demonstrates the same "personal team does not support X capability" template is used for capabilities withheld from free accounts). Stack Overflow #55828837 (32 votes, 77k views):

  > "Your development team, " ACCOUNT NAME", does not support the Push Notifications capability."

  and #57642860:

  > ""Your development account does not support domains and push notifications.""

### 2b. The user-visible behaviour in Settings — verbatim from a real screenshot

Stack Overflow #78412875 attaches a screenshot of iOS Settings from a device running a WireGuard/NetworkExtension app. I downloaded and read that image directly. **Transcribed verbatim from the screenshot** (nav title "VPN", status bar 1:50, iOS VPN pane):

> **VPN**
> VPN Status — Not Connected *(toggle greyed out / disabled)*
>
> ""AdhocVPN" must be updated by the developer before "Wireguard" can be connected."
>
> **DEVICE VPN**
> ✓ **Wireguard**
>  **AdhocVPN - Update Required**  *(rendered in red)*
>
> **Add VPN Configuration...**
>
> "VPNs can be set up to control the routing of certain network traffic. About VPNs & Privacy..."

Source image: <https://i.sstatic.net/bKsIVrUr.png> (linked from <https://stackoverflow.com/questions/78412875/>)

So the tunnel row **does** appear in the VPN list, but is marked "Update Required" and the master toggle is disabled.

### 2c. What I could NOT find

Explicitly **UNVERIFIED** — I searched for these and found **no** source containing them as literal error text from a Network Extension entitlement failure. **Do not treat any of these as real error strings:**

- `"Missing entitlement"` — not found in this context.
- `"No VPN profile"` — not found.
- `"Failed to save configuration"` — not found.
- Any error string that names `com.apple.developer.networking.networkextension` verbatim at runtime — not found.

**Interpretation (flagged as interpretation, not evidence):** the entitlement failure surfaces primarily at **code-signing / provisioning time** (Xcode refuses to build, cf. the "Personal development teams ... do not support Network Extensions Capability" string), *not* as a descriptive runtime error that names the missing entitlement. Where a sideload tool force-signs and bypasses that check, the app either fails at install/launch, or installs and the `NEVPNManager` / `NETunnelProviderManager` calls fail with a **generic** `NEVPNErrorDomain` error ("Permission Denied", error 2, or Code=5 "IPC failed") that does not mention entitlements at all. That generic-ness is precisely why these reports are hard to diagnose from the user side.

Apple documents the `NEVPNError.Code` cases as follows (<https://developer.apple.com/documentation/networkextension/nevpnerror-swift.struct/code>):

> "`case configurationDisabled` — An error code indicating the VPN configuration associated with the VPN manager isn't enabled."
> "`case configurationInvalid` — An error code indicating the VPN configuration associated with the VPN manager object is invalid."
> "`case connectionFailed` — The connection to the VPN server failed."
> "`case configurationStale` — An error code that indicates another process modfied the VPN configuration since the last time the app loaded the configuration."
> "`case configurationReadWriteFailed` — An error code that indicates an error occurred while reading or writing the Network Extension preferences."
> "`case configurationUnknown` — An error code that indicates that unspecified error occurred."

Notably, Apple documents **no error code meaning "missing entitlement"** — which is consistent with the community reports above.

---

## 3. What appears in Settings ▸ General ▸ VPN & Device Management

**Answer: on modern iOS, that single pane hosts both lists, and a sideloaded app touches both.** The signing/provisioning profile shows up under the profile side ("Device Management", labelled **"Developer App"** in current iOS), and a Network Extension app that successfully registers a configuration adds a second, separate entry under the VPN side. A sideloaded VPN app can therefore produce entries in *both* halves of the same screen — which is exactly why users confuse the two.

### Evidence

- **Apple's own wording that the pane holds the profile-trust UI, and that it applies to FREE accounts.** Apple Developer Documentation, *Restrictions* → `allowEnterpriseAppTrust` (read from <https://developer.apple.com/documentation/devicemanagement/restrictions>):

  > "`allowEnterpriseAppTrust`
  > `boolean`
  > If `false`, the system removes the Trust Enterprise Developer button in **Settings > General > VPN & Device Management**, which prevents provisioning apps by universal provisioning profiles. **This restriction applies to free developer accounts** and enterprise app developers that aren't implicitly trusted by apps that install through MDM. This restriction doesn't revoke previously granted trust.
  > Available: iOS 9+ | iPadOS 9+ | visionOS 2+
  > Default: `true`"

  This is the strongest Apple-authored link between **free developer accounts** and **Settings > General > VPN & Device Management**, and it identifies that pane as where the trust button lives.

  <https://developer.apple.com/documentation/devicemanagement/restrictions>

- **The sideloading tool's own documentation, naming the exact sub-section.** SideStore Docs, *Install* (current):

  > "1. Open the Settings app.
  > 2. Navigate to 'General', and then 'VPN & Device Management'.
  > 3. Under the **"Developer App"** section, select the option named after your Apple Account.
  > 4. Select "Trust \[Apple Account name\]", then select "Allow & Restart".
  > 5. Enter your passcode to confirm you want to trust the app.
  > 6. Navigate to 'Privacy and Security'.
  > 7. Scroll to the bottom, and turn on **"Developer Mode"**. Your device will restart.
  > 8. Open LocalDevVPN and select 'Connect'."

  Two things worth extracting: (a) the profile list is rendered under a heading literally called **"Developer App"** inside VPN & Device Management; (b) SideStore's own on-device refresh tunnel is a VPN configuration ("LocalDevVPN" → Connect), and Developer Mode lives in a **different** pane (Privacy & Security), not in VPN & Device Management.

  <https://docs.sidestore.io/docs/installation/install>

- **Independent (non-English) community confirmation for ESign/Scarlet-class tooling.** The widely-circulated Russian-language Scarlet troubleshooting guide ("Топ ошибки в Scarlet", 2023-07-09) tells users to trust the signing certificate at the same location, verbatim:

  > "ДОВЕРИЕ СЕРТИФИКАТУ
  > ## Решение:
  > 1.  Переходим в настройки
  > 2.  Переходим в раздел Основные
  > 3.  Ищем **VPN и управление устройством** и заходим туда
  > 4.  Находим там наш сертификат>нажимаем на него, а потом на кнопку доверять"

  ("CERTIFICATE TRUST / Solution: 1. Go to Settings 2. Go to the General section 3. Look for **VPN and device management** and go there 4. Find our certificate there, tap it, then tap the trust button.")

  <https://teletype.in/@wiiickeddd_0/NU0S4pXQrS_>

- **The VPN-list half of the same pane, verbatim from a device.** See the screenshot transcription in Point 2b: the app's tunnel appears as a row under the **DEVICE VPN** heading with a status sub-line, inside the **VPN** screen reachable from Settings ▸ General ▸ VPN & Device Management.

### What this means concretely for a sideloaded VPN app

| What the user sees | Which half of the pane | Notes |
|---|---|---|
| An entry named after their Apple ID / the signing cert, under a **"Developer App"** heading, with a **"Trust …"** button | Profile / Device Management side | Appears for essentially any free-Apple-ID sideload. Apple's `allowEnterpriseAppTrust` doc ties this button to free developer accounts. |
| A **DEVICE VPN** row named after the app's tunnel, possibly with a red **"Update Required"** sub-line | VPN configuration side | Only appears if the app got far enough to register a configuration. In the documented case it appears but the master toggle is disabled and it can never connect. |
| **"Developer Mode"** toggle | **NOT here** — it is in Settings ▸ Privacy & Security | Per SideStore docs step 6. Commonly misremembered as being in VPN & Device Management. |

### UNVERIFIED

- I did **not** find an Apple page that states in one sentence "this pane shows both the VPN list and the profile list". The dual nature is established here by combining Apple's `allowEnterpriseAppTrust` wording (profile-trust button lives there) with SideStore's step-by-step (VPN & Device Management → Developer App section) and the device screenshot (DEVICE VPN list). That is a synthesis, not a single quote.
- I found **no** report of a free-Apple-ID sideloaded VPN app where the DEVICE VPN row appeared and the tunnel **did** connect.

---

## 4. Apple's own documentation on Network Extension requiring a paid membership

**Important honesty note up front:** Apple's *entitlement reference page* for Network Extensions does **not** contain a sentence saying "a paid Apple Developer Program membership is required." The constraint is expressed indirectly — through the per-program capability table (Point 5) and through the Xcode/provisioning error surfaced by Apple's own DTS engineer (below). Anyone claiming a direct Apple quote saying "Network Extension requires a paid membership" is probably paraphrasing. I flag this because it matters for how confidently you can state the claim.

### Evidence

- **Apple Developer Forums thread 675195 — "Network Extension Capability"** (recovered via Wayback Machine; the live page is behind a bot wall and returns no content to non-browser clients). The developer asks:

  > "i am trying to make simple content filter as proof of concept and for debugging i should use real device , when i run the project on device Xcode returns this error "Personal development teams , including 'My Name' do not support Network Extensions Capability" , as i guess i should be an apple developer for not having this error , but is there a way to debugg the project while i am just trying to proof the concept?"

  **Apple's reply, from an Apple DTS engineer** (signature block: `Matt Eaton / DTS Engineering, CoreOS / meaton3@apple.com`):

  > "> is there a way to debugg the project while i am just trying to proof the concept?
  >
  > Not without code signing with the Network Extension capability tied to your Developer Account. [See here](https://developer.apple.com/support/compare-memberships/) for more information."

  This is the single most authoritative source found: an Apple engineer stating that a Personal Team **cannot** code-sign with the Network Extension capability, even for a proof-of-concept on the developer's own device.

  <https://developer.apple.com/forums/thread/675195> (archived: <https://web.archive.org/web/20220724114428id_/https://developer.apple.com/forums/thread/675195>)

- **Apple's Network Extensions Entitlement reference page** — read in full; quoted here so you can see exactly what it *does* and *does not* say. (<https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension>)

  > "**Network Extensions Entitlement**
  > The APIs an app can use to customize networking features."
  >
  > "Key `com.apple.developer.networking.networkextension`  Type array of strings"
  >
  > "**Possible values**
  > `dns-proxy` — The APIs you use to proxy DNS queries.
  > `app-proxy-provider` — The APIs you use to proxy TCP and UDP connections.
  > `content-filter-provider` — The filter APIs you use to allow or deny network connections created by other apps on the system.
  > `packet-tunnel-provider` — The APIs you use to tunnel IP packets to a remote network using any custom tunneling protocol.
  > ..."
  >
  > "**Discussion**
  > To add this entitlement to an App Store app, enable the Network Extensions capability in Xcode.
  > To add this entitlement to a macOS app distributed outside of the Mac App Store, perform the following steps:
  > 1. In the Certificates, Identifiers and Profiles section of the developer site, enable the Network Extension capability for your Developer ID–signed app. Generate a new provisioning profile and download it.
  > 2. On your Mac, drag the downloaded provisioning profile to Xcode to install it.
  > 3. In your Xcode project, enable manual signing and select the provisioning profile downloaded earlier and its associated certificate.
  > 4. Update the project's `entitlements.plist` to include the `com.apple.developer.networking.networkextension` key and the values of the entitlement."

  **Note what is absent: no mention of program membership tiers, no mention of Personal Team, no "requires a paid membership" sentence.** The membership constraint is enforced by the provisioning system, documented in the capability table, not on this page.

- **`com.apple.developer.networking.vpn.api` (Personal VPN Entitlement)** is documented separately and is a *different* entitlement from the one above. Apple's summary: "The API an app can use to create and control a custom system VPN configuration." (`NEVPNManager`, as used in the PlayCover report.) Both are absent from the free tier per Point 5.

- **Accepted community answer on the iOS question**, quoted in full in Point 1: *"The free tier "Apple Developer" cannot add network extensions or personal VPN capabilities. You will need a paid Apple Developer Program membership."*
  <https://stackoverflow.com/questions/77974220/>

- **The macOS-side equivalent**, Stack Overflow #63476574, "Is there a way to add the Network Extensions capability to a macOS app without joining the Apple Developer Program?" (2020). The asker answers their own question:

  > "I figured out the answer to my question: to write macOS software that uses the NetworkExtension APIs, you must be a member of the Apple Developer Program ($100/year). See https://developer.apple.com/support/app-capabilities/ for details."

  The 6-upvote answer by `pmdj` describes the only known bypass and confirms Xcode is the enforcer:

  > "You *should* be able to do it if you disable system integrity protection (SIP) on your Mac (`csrutil disable` in the Terminal in the macOS Recovery Environment), and disable `amfid`'s entitlements check by adding `amfi_get_out_of_my_way=1` to the kernel's command line arguments."
  >
  > "You will need to bypass Xcode when code signing and use the `codesign` command directly because **Xcode performs the provisioning profile entitlements check**, as you noticed. `codesign` itself does not perform this check."

  This explains the sideloading picture precisely: third-party sideload tools effectively play the role of `codesign` and skip the check, which is why the **app installs** but the **tunnel still fails at runtime** — iOS itself still refuses to honour the unprovisioned entitlement.

  <https://stackoverflow.com/questions/63476574/>

### Could not read (flagged, NOT quoted)

- **`developer.apple.com/forums/thread/816045`** — titled in search-result metadata as *"Do I need to request Packet Tunnel Provider entitlement from Apple to get my app working?"*. No Wayback snapshot exists (`web.archive.org/cdx` → `[]`), and the live page is bot-walled. **I did not read this thread and quote nothing from it.**
- **`developer.apple.com/forums/thread/750719`** — surfaced in search-result metadata with the title *"VPN: "AppName" must be updated bu the developer before "VpnName" can be connected"*, which appears to document the same Settings message transcribed in Point 2b. Also **no archive** (`cdx` → `[]`), bot-walled. **I did not read this thread.** The Settings text itself is nevertheless verified independently from the screenshot in Point 2b, so this thread is corroboration-by-title only and adds nothing you need.

---

## 5. Apple's official list of capabilities available to FREE (Personal Team) accounts

**Yes — Apple publishes exactly such a page, and Network Extensions and Personal VPN are both absent for the free tier.** App Groups and Push Notifications are listed in the same table.

### Evidence — Apple's official page

Apple Developer, *Account Help ▸ Reference ▸* **"Supported capabilities (iOS)"**
<https://developer.apple.com/help/account/reference/supported-capabilities-ios>

Opening statement, verbatim:

> "# Supported capabilities (iOS)
>
> The capabilities available to an iOS provisioning profile depend on your program membership."

The table's three program columns are defined verbatim at the foot of the page:

> "**ADP:** Apple Developer Program membership. Members of this paid program can distribute apps on the App Store."
>
> "**ADEP:** Apple Developer Enterprise Program membership. Members of this paid program can distribute apps to employees within an organization."
>
> "**Apple Developer:** Apple Account holders who have agreed to the Apple Developer Agreement to access certain resources on the Apple Developer website. **No cost is associated with this agreement and developers can't distribute apps.**"

The final column, **"Apple Developer"**, is therefore the free / Personal Team tier.

The rows relevant to this research, reproduced from the table (the page renders membership as tick marks; see the screenshot verification below for which cells are ticked):

> `| Capability | ADP | ADEP | Apple Developer |`
>
> `| App groups | … | … | … |`
> `| Network extensions | … | … | … |`
> `| Personal VPN | … | … | … |`
> `| Push notifications | … | … | … |`

*(Note: the raw table text also contains a row `On Demand Install Capable`. Other rows include `5G Network Slicing`, `Access Control`, `App Attest`, `Apple Pay`, `Associated domains`, `Background modes`, `HealthKit`, `HomeKit`, `iCloud: CloudKit`, `In-App Purchase`, `Keychain sharing`, `Maps`, `Sign in with Apple`, `Siri`, `Wallet`, `WeatherKit`, and more.)*

### Evidence — the tick marks, verified visually

The page's membership ticks do not survive text extraction (they render as blank cells). I recovered them by downloading and reading the screenshot of the same Apple table that Paulw11 attached to the accepted Stack Overflow answer (#77974220, Feb 2024). **Read directly from the image** — this is a crop showing the capability name and the ADP / ADEP / Apple Developer columns:

> | Capability | ADP | ADEP | Apple Developer |
> |---|---|---|---|
> | **Network extensions** | ✔ | ✔ | *(blank)* |
> | On Demand Install Capable | ✔ | *(blank)* | *(blank)* |
> | **Personal VPN** | ✔ | ✔ | *(blank)* |

Source image: <https://i.sstatic.net/1csOW.jpg> (attached to <https://stackoverflow.com/questions/77974220/>)

**Conclusion, with the confidence level stated:** for the free ("Apple Developer") column, **Network extensions has no tick and Personal VPN has no tick**. This is corroborated by the answer text ("The free tier "Apple Developer" cannot add network extensions or personal VPN capabilities."), by Apple DTS in thread 675195, and by the sideloading-tool maintainers in Point 1.

### App Groups and Push Notifications — partial verification

The user asked specifically about these two, so here is what I actually verified versus not:

- **Push notifications — verified NOT available on free accounts**, but from *independent* sources rather than from reading the tick mark. Stack Overflow #55828837, "Your development team does not support the Push Notifications capability" (32 votes, 77,867 views), quotes the exact Xcode error: `"Your development team, " ACCOUNT NAME", does not support the Push Notifications capability."` And #57642860 reports `""Your development account does not support domains and push notifications.""` from a user signing with a plain (free) Apple ID. <https://stackoverflow.com/questions/55828837/> · <https://stackoverflow.com/questions/57642860/>

- **App groups — UNVERIFIED.** The row exists in Apple's table, but my screenshot crop (reproduced above) covers only the `Network extensions` → `On Demand Install Capable` → `Personal VPN` region, so **I never saw the `App groups` tick marks**. I also could not locate a reliable statement about App Groups on Personal Teams. A targeted Stack Overflow API search (`App Groups personal team free account Xcode`) returned **zero** items. **Do not assert the App Groups status from this report.** The `App groups` row is nonetheless listed in Apple's table; only its per-column ticks are unverified here.

### Related rows worth noting

The same Apple page carries a Notes block:

> "If you aren't a member of the Apple Developer Program, you can use the MapKit framework but you can't provide routing directions. The ability to upload geolocation files in App Store Connect is only included with membership in the Apple Developer Program."

and marks certain rows `* Development only`.

---

## Bottom line

1. **Does the free-Apple-ID sideloaded VPN app install?** Generally **yes** — the IPA is signed and installs, and the signing profile appears in Settings ▸ General ▸ VPN & Device Management under the **"Developer App"** heading. (Evidence: AltStore #1091 — *"everything works fine, but the Network Extension (aka. "VPN") cannot be installed"*; SideStore install docs.)
2. **Does it launch?** Usually **yes**. (PlayCover #1241 — *"The app opens normally ... but fails when creating the VPN connection"*.)
3. **Does the tunnel work?** **No** — on every concrete report found. Either the Network Extension component cannot be installed at all (AltStore #1091), or the app hits `saveToPreferences()` → "Permission Denied" (PlayCover #1241), or the tunnel registers in Settings but is permanently "Update Required" with the master toggle disabled (SO #78412875, transcribed in Point 2b), or `NEVPNManager`/`NETunnelProviderManager` fails with a generic `NEVPNErrorDomain` error (SO #46621292; wireguard_flutter #12 `Code=5 "IPC failed"`).
4. **Why:** `com.apple.developer.networking.networkextension` and `com.apple.developer.networking.vpn.api` are absent from the free "Apple Developer" column of Apple's capability table. Xcode enforces this at provisioning time (`"Personal development teams ... do not support Network Extensions Capability"`); third-party sideload tools bypass Xcode's check but cannot make iOS honour the unprovisioned entitlement. Apple DTS: *"Not without code signing with the Network Extension capability tied to your Developer Account."*

**Residual uncertainty, stated plainly:** no Reddit evidence was obtainable; no Tailscale/sing-box-specific report was found; the `App groups` tick for free accounts is unverified; and the numeric mapping `NEVPNErrorDomain 2 == configurationDisabled` is inferred rather than documented.
