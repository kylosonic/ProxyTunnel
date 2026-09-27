# Installing the unsigned IPA with Sideloadly

The complete workflow, including every way it can fail and what the failure
means.

**Read [`ENTITLEMENTS-AND-SIGNING.md`](ENTITLEMENTS-AND-SIGNING.md) first if you
have not.** The short version: this installs and runs, but the VPN does not, and
that is an Apple licensing restriction rather than a bug.

---

## What you need

| | |
|---|---|
| **Sideloadly** | <https://sideloadly.io> — Windows or macOS |
| **iPhone** | iOS 16 or later, connected by cable, trusted on the computer |
| **Apple ID** | A free one is fine. Have your 2FA device ready |
| **The IPA** | `ProxyTunnel.ipa` from the Actions artifact |

Optional but recommended: [iTunes](https://www.apple.com/itunes/) or the Apple
Devices app on Windows, because Sideloadly relies on Apple's device drivers
(`libimobiledevice`) and they are much happier when iTunes has installed them
first.

---

## 1. Get the IPA

1. Open the repository's **Actions** tab.
2. Select **Build iOS IPA**.
3. Either wait for a `push` build, or click **Run workflow**:
   * **bundle_id** — change this to something unique to you. See
     [step 2](#2-change-the-bundle-identifier-first-time-only).
   * **configuration** — leave as `Release`.
   * **run_tests** — leave as `true`.
4. Wait for the green tick. A cold run takes 10–15 minutes: the runner has to
   install XcodeGen, generate the project, build two targets, boot a simulator,
   run the tests, and package and validate the IPA.
5. On the finished run page, scroll to **Artifacts**:
   * **`ProxyTunnel-iOS-unsigned`** — the IPA, plus SHA-256, provenance and the
     validation report.
   * **`ProxyTunnel-iOS-build-logs`** — full `xcodebuild` output for both
     targets, the test results bundle, toolchain information and the simulator
     list.
6. Download and unzip `ProxyTunnel-iOS-unsigned` → `ProxyTunnel.ipa`.

Verify it if you like:

```bash
shasum -a 256 ProxyTunnel.ipa
# compare with sha256.txt in the artifact
```

## 2. Change the bundle identifier (first time only)

Free Apple ID signing registers App IDs **globally**. If somebody else has
already taken `io.github.kylosonic.proxytunnel`, your registration fails with
"maximum App ID limit reached" or a duplicate-identifier error.

Pick something only you will use:

* edit `BUNDLE_ID_BASE` in [`project.yml`](../project.yml), **or**
* pass `bundle_id` to the workflow dispatch, **or**
* use Sideloadly's own bundle-ID field.

A reverse-DNS string you control is the right shape:
`com.yourname.proxytunnel`, `io.github.youruser.proxytunnel`.

The app is written for the possibility that Sideloadly rewrites the identifier:
it reads the extension's real bundle identifier out of the embedded `.appex` at
runtime, rather than assuming `<app>.tunnel`. If it assumed, the VPN configuration
would point at a bundle identifier that does not exist and `saveToPreferences`
would fail with a generic error.

## 3. Sign and install

1. **Open Sideloadly** with the iPhone connected. It should detect the device.
2. **Drag `ProxyTunnel.ipa`** onto the Sideloadly window, or use the file picker.
3. **Enter your Apple ID** in the Apple ID field.

   > ### ⚠️ Do not enable "Remove Extensions" / "Remove PlugIns"
   >
   > That option deletes `Payload/ProxyTunnel.app/PlugIns/ProxyTunnelExtension.appex`
   > — the entire tunnel. The app will still install and run, and its Diagnostics
   > screen will report that no PlugIns directory exists. If you already did this,
   > re-run the install with the option off.

4. **Click Start.** Sideloadly will:
   * authenticate to Apple and, if needed, ask for your 2FA code;
   * register an App ID for the app **and** one for the extension;
   * request a development certificate;
   * fetch a 7-day provisioning profile covering both;
   * sign the main binary and the nested `.appex`;
   * install over `libimobiledevice`.
5. **Wait.** The first run does a lot of Apple round-trips. Two to five minutes is
   normal.

## 4. Trust the app

On the iPhone:

**Settings ▸ General ▸ VPN & Device Management ▸ Developer App** → tap your Apple
ID → **Trust**.

The app icon will be visible on the Home Screen before you do this, but it will
refuse to launch.

## 5. Confirm what you got

Open the app and go to **Settings ▸ Diagnostics ▸ Signing & entitlements**.

You will see something like:

```
Extension profile
  Profile: iOS Team Provisioning Profile: io.github.you.proxytunnel.tunnel
  App identifier: ABCDE12345.io.github.you.proxytunnel.tunnel
  Team: ABCDE12345
  Validity: 2026-01-01 10:00 → 2026-01-08 10:00
  com.apple.developer.networking.networkextension: ABSENT
  com.apple.developer.networking.vpn.api: absent
  com.apple.security.application-groups: group.io.github.you.proxytunnel
  STATE: this profile has a short (≈7 day) lifetime, which is what free Apple ID
         provisioning produces. It must be renewed regularly.
```

`ABSENT` on the Network Extension key is the expected result for a free Apple ID,
and the screen will say so in plain language.

Two other things this screen tells you:

* **Credential delivery** — whether the App Group container is available (so the
  password stays out of the system VPN preferences) or whether the inline
  fallback is in use.
* **App Group ID** and whether it is actually available in this process.

## 6. Test the proxy anyway — this is the useful part

The proxy client works perfectly well under free signing; only the tunnel does
not. So verify your proxy:

1. **Proxies** tab → **+**.
2. Fill in name, host, port, protocol, username, password.
3. Tap **Test connection**.

You should see something like:

```
✔ The proxy relayed traffic
Proxy host resolved to 203.0.113.7
TCP connect to 203.0.113.7: OK (84 ms)
Proxy handshake: SOCKS5 CONNECT succeeded (61 ms)
HTTP request through the proxy: status 200
Traffic exited via 198.51.100.4
Total 1.4 s
```

`Traffic exited via …` is the IP address the origin server saw — your proxy's
egress address. Nothing about that is simulated: it is a real TCP connection to
your proxy, a real `CONNECT`, a real HTTP request through the tunnel, and a real
response.

If that works, your proxy and credentials are correct, and the only thing
standing between you and a working VPN is the Apple Developer Program.

## 7. Try CONNECT (optional)

Tap **CONNECT**. The app will:

1. resolve the proxy host;
2. build the configuration;
3. call `saveToPreferences`;
4. fail, with **"iOS refused to save the VPN configuration (permission denied)"**
   and a pointer to the Diagnostics screen.

That is `NEVPNErrorDomain` code 5. iOS never mentions entitlements in that
message, which is exactly why the app inspects its own provisioning profile and
tells you directly.

## 8. Afterwards

### The app expires after 7 days

Free provisioning profiles are valid for **7 days**. When the app stops
launching, re-run Sideloadly with the same IPA. Your proxy profiles and passwords
survive: the Keychain access group is derived from the team identifier and bundle
identifier, both of which stay the same.

### Free account limits

From Apple:

> You can register up to 10 App IDs, which expire after 7 days.
>
> You can register up to 3 devices, which expire after 7 days.
>
> You can install up to 3 apps per device.

An app with an extension uses **more than one App ID** — ProxyTunnel uses two
(the app and the extension). Sideloadly shows the remaining count.

### If you later get a Developer Program membership

Nothing in the source changes. Sign the same IPA with a paid certificate and a
profile that includes **Network Extensions**, and the tunnel works. See
[`SIGNED-BUILDS.md`](SIGNED-BUILDS.md).

---

## When it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `The maximum number of apps for free development profiles has been reached` | 3 apps on the device already | Delete one, or remove an old Sideloadly-installed app |
| `Your maximum App ID limit has been reached` | 10 App IDs registered in the last 7 days | Wait, or use a different Apple ID |
| `The executable was signed with invalid entitlements` (`0xE8008016`) | Signed entitlements do not match the profile | Re-run with **Remove Extensions off**; if it persists, the IPA may have been modified in transit — re-download it |
| App installs but will not launch | Not trusted yet | Settings ▸ General ▸ VPN & Device Management ▸ Trust |
| App launches, Diagnostics says "no PlugIns directory" | **Remove Extensions** was enabled | Reinstall with it off |
| `PackageInspectionFailed` | The installer disliked the IPA's structure | Run `Scripts/validate-ipa.sh ProxyTunnel.ipa` and compare against the CI validation report |
| `AppexBundleUnknownExtensionPointIdentifier` | The extension's `NSExtensionPointIdentifier` is wrong | Should be `com.apple.networkextension.packet-tunnel`; the validator checks it |
| `AppexBundleIDNotPrefixed` | The extension's bundle ID is not a child of the app's | Caused by bundle-ID rewriting; set an explicit `bundle_id` in the workflow and in Sideloadly |
| Sideloadly cannot see the device | Missing Apple device drivers | Install iTunes, or the Apple Devices app on Windows |
| 2FA prompt loops | Sideloadly's anisette session expired | Restart Sideloadly; try switching between Remote and Local Anisette if offered |
| Everything succeeds but CONNECT says "permission denied" | **This is the expected outcome.** Free Apple IDs cannot provision Network Extensions | Nothing. It is Apple's restriction. See [`ENTITLEMENTS-AND-SIGNING.md`](ENTITLEMENTS-AND-SIGNING.md) |

---

## What Sideloadly does and does not document

Worth knowing, because some of it matters for this app.

**Documented:**

* Free Apple ID signing, anisette handling, App ID registration and 7-day
  profiles.
* App extensions are supported, and *removal* is offered as a fallback:
  "Remove Extensions — Remove individual or all app extensions (PlugIns) before
  install."
* Bundle identifiers may be rewritten: *"Apple has prevented users on free Apple
  accounts from sideloading apps that have the same bundle ID as an App Store
  app. As a result, we are forced to set a unique bundle ID."*
* Custom entitlements are a paid feature (0.60.0: *"Added support for custom app
  entitlements (Apple Developer Program only)"*).
* Custom certificates are **not** supported: *"This is not currently supported
  but it's a feature we'd like to add."* There is no `.p12` / `.mobileprovision`
  flow.

**Not documented, and therefore unverified:** whether Sideloadly strips
entitlements the free profile cannot support. No FAQ entry, changelog line or
developer statement describes it. Both outcomes are seen in the wild — an
`0xE8008016` install failure, or an install that succeeds and a capability that
silently does not work. The second is far more common, and it is the shape of the
outcome here.

The mechanics explain why "signing succeeded" does not mean "the entitlement
works": Xcode performs an entitlement/profile consistency check at signing time;
`codesign` itself does not. Third-party tools skip that check, so they can produce
a signature that installs — and then iOS refuses to honour the entitlement at
runtime, because it validates against the profile itself.

Full detail, with sources and confidence labels, in
[`research/sideloadly-free-apple-id-report.md`](research/sideloadly-free-apple-id-report.md).
