# TrollStore & Entitlements — Publicly Documented Capability Boundaries

**Research date:** 2026 (sources fetched live; GitHub release data from the GitHub Releases API)
**Scope:** capability statements and version ranges only. No exploitation steps, jailbreak procedures, or how-to content is included or inferred.
**Primary sources:** `opa334/TrollStore` README at tags `main` / `2.0` / `1.5.1`, GitHub Releases, repository source code, issue tracker; `ios.cfw.guide`; opa334's own Havoc package listing.
**Secondary sources:** third-party project docs (EasyTier, CB-Pro-Proxy) and alfiecg24's 2025 conference deck.

**Quote-integrity note:** README/issue/web quotes below were fetched directly and are verbatim (including original typos and British/`-ise` spellings). Quotes from alfiecg24's deck were recovered by decompressing the PDF's content streams and extracting text-show operators, so slide bullet text is faithful but ligatures (`fi`/`ffi`) and line-break ordering may differ slightly from the rendered slide; nothing has been paraphrased into a quote.

---

## 1. What the TrollStore README / official docs say about installing IPAs "with arbitrary entitlements"

**Finding:** The exact phrase *"arbitrary entitlements"* appears verbatim in both the repository's official GitHub description and the README's **Features** section.

### Evidence:

- Repository description (official, set by the maintainer) — contains the original typo *"arbitary"*:
  > "Jailed iOS app that can install IPAs permanently with arbitary entitlements and root helpers because it trolls Apple"
  — https://github.com/opa334/TrollStore (retrieved via GitHub repository API: `https://api.github.com/repos/opa334/TrollStore`)

- README (current `main`), opening line:
  > "TrollStore is a permasigned jailed app that can permanently install any IPA you open in it."
  — https://github.com/opa334/TrollStore/blob/main/README.md

- README (current `main`), **Features** section — the canonical "arbitrary entitlements" statement:
  > "The binaries inside an IPA can have arbitrary entitlements, fakesign them with ldid and the entitlements you want (`ldid -S<path/to/entitlements.plist> <path/to/binary>`) and TrollStore will preserve the entitlements when resigning them with the fake root certificate on installation. This gives you a lot of possibilities, some of which are explained below."
  — https://github.com/opa334/TrollStore/blob/main/README.md

- The identical sentence is present unchanged in older tags, confirming it is long-standing official wording:
  - https://raw.githubusercontent.com/opa334/TrollStore/2.0/README.md
  - https://raw.githubusercontent.com/opa334/TrollStore/1.5.1/README.md

- Independent documentation (iOS Guide / cfw.guide) uses a hedged version of the same claim:
  > "TrollStore is a utility which is able to permanently sign and install any application with almost any entitlement with the help of a CoreTrust bug."
  — https://ios.cfw.guide/installing-trollstore/
  (Note the hedge **"almost any entitlement"** — the guide does *not* say "any".)

- alfiecg24 (author of the CoreTrust bypass used in TrollStore 2.x), "The State of iOS Jailbreaking in 2025" deck, CoreTrust section:
  > "Any and all entitlements* are allowed"
  > "Apart from three that were restricted to trustcached processes only"
  — https://raw.githubusercontent.com/alfiecg24/Presentations/main/The%20State%20of%20iOS%20Jailbreaking%20in%202025.pdf
  (The asterisk is the slide's own; the "three" are enumerated in section 6 below.)

---

## 2. Supported / vulnerable iOS versions per major release

**Finding:** The current README **no longer contains a "supported versions" / installation-methods table.** It states a single supported-versions line and delegates device/version-specific install methods to ios.cfw.guide. The tables existed in the 1.x and 2.0-era READMEs and are reproduced verbatim below; the current authoritative matrix is the ios.cfw.guide table.

### 2a. Current README (`main`) — the only version statement it makes

- > "Supported versions: 14.0 beta 2 - 16.6.1, 16.7 RC (20H18), 17.0"
  — https://github.com/opa334/TrollStore/blob/main/README.md

- > "16.7.x (excluding 16.7 RC) and 17.0.1+ will NEVER be supported (unless a third CoreTrust bug is discovered, which is unlikely)."
  — https://github.com/opa334/TrollStore/blob/main/README.md

- > "For installing TrollStore, refer to the guides at [ios.cfw.guide](https://ios.cfw.guide/installing-trollstore)"
  — https://github.com/opa334/TrollStore/blob/main/README.md

### 2b. TrollStore 1.x README table (verbatim, tag `1.5.1`)

- > "| Version / Device | arm64 (A8 - A11) | arm64e (A12 - A15, M1) |"
  > "| 13.7 and below | Not Supported (CT Bug only got introduced in 14.0) | Not Supported (CT Bug only got introduced in 14.0) |"
  > "| 14.0 - 14.8.1 | [checkra1n + TrollHelper](./install_trollhelper.md) | [TrollHelperOTA (arm64e)](./install_trollhelperota_arm64e.md) |"
  > "| 15.0 - 15.4.1 | [TrollHelperOTA (iOS 15+)](./install_trollhelperota_ios15.md) | [TrollHelperOTA (iOS 15+)](./install_trollhelperota_ios15.md) |"
  > "| 15.5 beta 1 - 4 | [TrollHelperOTA (iOS 15+)](./install_trollhelperota_ios15.md) | [TrollHelperOTA (iOS 15+)](./install_trollhelperota_ios15.md) |"
  > "| 15.5 (RC) | Not Supported (CT Bug fixed) | Not Supported (CT Bug fixed) |"
  > "| 15.6 beta 1 - 5 | [SSH Ramdisk](./install_sshrd.md) | [TrollHelperOTA (arm64e)](./install_trollhelperota_arm64e.md) |"
  > "| 15.6 (RC1/2) and above | Not Supported (CT Bug fixed) | Not Supported (CT Bug fixed) |"
  — https://raw.githubusercontent.com/opa334/TrollStore/1.5.1/README.md

- Immediately following that table (1.x era, since superseded):
  > "This version table is final, TrollStore will never support anything other than the versions listed here. Do not bother asking, if you got a device on an unsupported version, it's best if you forget TrollStore even exists."
  — https://raw.githubusercontent.com/opa334/TrollStore/1.5.1/README.md

### 2c. TrollStore 2.0 transitional README table (verbatim, tag `2.0`)

- > "| 13.7 and below | Not Supported (Both CT Bugs only got introduced in 14.0) | Not Supported (Both CT Bugs only got introduced in 14.0) |"
  > "| 14.0 - 14.8.1 | [checkra1n + TrollHelper](./install_trollhelper.md) | [TrollHelperOTA (arm64e)](./install_trollhelperota_arm64e.md) |"
  > "| 15.0 - 15.4.1 | [TrollHelperOTA (iOS 15+)](./install_trollhelperota_ios15.md) | [TrollHelperOTA (iOS 15+)](./install_trollhelperota_ios15.md) |"
  > "| 15.5 beta 1 - 4 | [TrollHelperOTA (iOS 15+)](./install_trollhelperota_ios15.md) | [TrollHelperOTA (iOS 15+)](./install_trollhelperota_ios15.md) |"
  > "| 15.5 | Coming Soon | Coming Soon |"
  > "| 15.6 beta 1 - 5 | [TrollHelperOTA (iOS 15+)](./install_trollhelperota_ios15.md) | [TrollHelperOTA (iOS 15+)](./install_trollhelperota_ios15.md) |"
  > "| 15.6 - 16.5 | Coming Soon | Coming Soon |"
  > "| 16.5.1 - 16.6.1 | Coming Soon | No Installation Method |"
  > "| 16.7 - 16.7.2 | Not Supported (Both CT Bugs fixed) | Not Supported (Both CT Bugs fixed) |"
  > "| 17.0 | Coming Soon | No Installation Method |"
  > "| 17.0.1 and newer | Not Supported (Both CT Bugs fixed) | Not Supported (Both CT Bugs fixed) |"
  — https://raw.githubusercontent.com/opa334/TrollStore/2.0/README.md

- > "Due to the discovery of a new CoreTrust vulnerability, support for 15.5 - 16.6.1 and 17.0 will be added in the future. Stay on these versions if you want TrollStore. 16.7 and 17.0.1+ will NEVER be supported (unless Apple fucks CoreTrust up a third time...)."
  — https://raw.githubusercontent.com/opa334/TrollStore/2.0/README.md

### 2d. TrollStore 2.0 release note — the CVE that extended support to 15.5–16.6.1 / 17.0

- > "Add support for iOS 15.5 - 16.6.1, 17.0 thanks to CVE-2023-41991 (Note that not all devices / versions have an install method, kfd devices will get one shortly by misaka, checkm8 devices can use the TrollHelper package, the arm64e OTA method has been updated to support a few more versions of iOS 15, which exactly we do not know yet, but 15.5 is definitely supported by it now)"
  — TrollStore 2.0 release notes, https://github.com/opa334/TrollStore/releases/tag/2.0

### 2e. Current full version/devices matrix (ios.cfw.guide, verbatim)

- > "| From | To | arm64 (A8) | arm64 (A9-A11) | arm64e (A12-A17/M1-M2) |"
  > "| 14.0 beta 1 and earlier | Unsupported |"
  > "| 14.0 beta 2 | 14.8.1 | [TrollInstallerX] | [TrollHelperOTA] |"
  > "| 15.0 | 15.5 beta 4 | [TrollHelperOTA] |"
  > "| 15.5 | 15.5 | [TrollInstallerMDC] | [TrollInstallerX] | [TrollHelperOTA] |"
  > "| 15.6 beta 1 | 15.6 beta 3 | [TrollHelperOTA] |"
  > "| 15.6 beta 4 | 15.6.1 | [TrollInstallerMDC] | [TrollInstallerX] | [TrollHelperOTA] |"
  > "| 15.7 | 15.7.1 | [TrollInstallerMDC] | [TrollInstallerX] |"
  > "| 15.7.2 | 15.8.6 | [TrollMisaka] | [TrollInstallerX] |"
  > "| 15.8.7 | 15.8.8 | [TrollRestore] | Not Applicable |"
  > "| 16.0 beta 1 | 16.0 beta 5 | Not Applicable | [TrollInstallerX] | [TrollHelperOTA] |"
  > "| 16.0 beta 6 | 16.6.1 | Not Applicable | [TrollInstallerX] |"
  > "| 16.7 RC | 16.7 RC | Not Applicable | [TrollRestore] |"
  > "| 16.7 | 16.7.16 | Not Applicable | Unsupported |"
  > "| 17.0 beta 1 | 17.0 beta 4 | Not Applicable | [TrollInstallerX] | [TrollRestore] |"
  > "| 17.0 beta 5 | 17.0 | Not Applicable | [TrollRestore] |"
  > "| 17.0.1 and later | Not Applicable | Unsupported |"
  — https://ios.cfw.guide/installing-trollstore/
  (Link markup flattened to labels for readability; the page renders each tool name as a hyperlink. All other text is verbatim.)

- > "If your device is on iOS 14.0 *beta 1* or earlier, is running iOS 16.7.x (excluding 16.7 RC (20H18)), or is running iOS 17.0.1 or newer, it will **never** be supported by TrollStore."
  — https://ios.cfw.guide/installing-trollstore/

### 2f. 2024–2026 updates

**TrollStore (jailed, non-jailbroken) version range has not changed since 2.0 (November 2023).** The 2024–2026 releases did not extend the supported iOS range; they added a separate jailbroken variant.

- TrollStore **2.1** (published 2024-09-02):
  > "Happy 2nd anniversary, TrollStore!"
  > "Introduce TrollStore Lite (https://havoc.app/package/trollstorelite) for jailbroken iOS versions"
  > "Add support for transferring installed apps between TrollStore and TrollStore Lite (So people using TrollStore for versions it was never intended for can switch to TrollStore Lite seamlessly)"
  > "Add 'Refresh App Registrations' option inside TrollStore settings"
  — https://github.com/opa334/TrollStore/releases/tag/2.1

- TrollStore **2.1.1** (published 2026-04-01) — the latest release as of this research:
  > "TrollStore Lite: Fix a typo in an entitlement that would make installed apps not work as excepted when the device is jailbroken with Dopamine"
  — https://github.com/opa334/TrollStore/releases/tag/2.1.1

- **TrollStore Lite** (opa334's own package listing on the Havoc repo):
  > "TrollStore Lite — TrollStore for jailbroken iOS"
  > "iOS COMPATIBILITY — 14.0 - 26.0.1"
  > "Jailbreak Required"
  > "VERSION — 2.1.1"
  — https://havoc.app/package/trollstorelite
  Version history confirms only 2.1 and 2.1.1: https://havoc.app/package/trollstorelite/changes

- alfiecg24's deck maps the two bugs to the two support ranges:
  > "Used in TrollStore 1.x to support iOS 14.0 - 15.5b4, 15.6 betas"
  > "Used in TrollStore 2.x to support iOS 14.0 - 16.7RC and 17.0"
  > "Since iOS 14, there have been two public CoreTrust bypasses"
  — https://raw.githubusercontent.com/alfiecg24/Presentations/main/The%20State%20of%20iOS%20Jailbreaking%20in%202025.pdf

---

## 3. Network Extension / VPN entitlements (`com.apple.developer.networking.networkextension`, `com.apple.developer.networking.vpn.api`) without a paid Apple Developer account

**Finding (honest summary):**
- **No official TrollStore documentation** (README at any tag, source comments, or maintainer statements) mentions either entitlement key by name. Whether they work is therefore governed only by the general "arbitrary entitlements" claim — **UNVERIFIED as an official, entitlement-specific statement.**
- The README's documented list of entitlements that do **not** work ("Banned entitlements", section 6) does **not** include either key.
- There **is** documented third-party evidence that a TrollStore IPA can carry `com.apple.developer.networking.networkextension` (`packet-tunnel-provider`) with **no Apple credentials**, from a shipping project's own build documentation.
- **`com.apple.developer.networking.vpn.api` (Personal VPN): UNVERIFIED.** No TrollStore-specific documentation or report for this key was found at all.

### Evidence — official TrollStore docs: nothing specific

- No occurrence of `networkextension`, `network extension`, `vpn.api`, `NEPacketTunnelProvider`, or `NETunnelProviderManager` exists in the TrollStore README (any tag checked) or in the repository's only two markdown files (`README.md`, `Victim/README.md`). Verified by fetching the READMEs and cloning/grepping the repository at `main`.
  — https://github.com/opa334/TrollStore/blob/main/README.md · https://raw.githubusercontent.com/opa334/TrollStore/2.0/README.md · https://raw.githubusercontent.com/opa334/TrollStore/1.5.1/README.md
- The only entitlement keys the README names as unusable are the three in "Banned entitlements" (section 6). Neither network key appears there. — https://github.com/opa334/TrollStore/blob/main/README.md

### Evidence — positive, from a shipping project that builds for TrollStore without credentials

**EasyTier iOS/macOS client** (a Network Extension VPN client) documents a dedicated TrollStore build:

- English README:
  > "### Nightly TrollStore build"
  > "On every push to `main`, the repository updates a credentials-free nightly Release IPA for TrollStore. The app and its extensions are ad-hoc signed with their required Network Extension and App Group entitlements."
  — https://raw.githubusercontent.com/EasyTier/EasyTier-iOS/main/README.md

- Chinese README, same statement:
  > "### TrollStore IPA"
  > "每次提交推送到 `main` 分支时，仓库都会自动更新供 TrollStore 安装的 Nightly Release IPA。构建不需要 Apple 凭据，并会使用项目所需的网络扩展与 App Group entitlements 进行 ad-hoc 签名。"
  ("The build does not require Apple credentials, and ad-hoc signs with the network extension and App Group entitlements the project requires.")
  — https://raw.githubusercontent.com/EasyTier/EasyTier-iOS/main/README_CN.md

- The project's actual entitlements file for its packet-tunnel provider extension:
  > `<key>com.apple.developer.networking.networkextension</key>`
  > `<array>`
  > `    <string>packet-tunnel-provider</string>`
  > `</array>`
  > `<key>com.apple.security.application-groups</key>`
  > `<array>`
  > `    <string>group.cn.easytier</string>`
  > `</array>`
  — https://raw.githubusercontent.com/EasyTier/EasyTier-iOS/main/EasyTierNetworkExtension/EasyTierNetworkExtension.entitlements
  (Corroborating file listing: https://github.com/EasyTier/EasyTier-iOS — `EasyTier/EasyTier.entitlements`, `EasyTierNetworkExtension/EasyTierNetworkExtension.entitlements`, `EasyTierWidgetExtension/EasyTierWidgetExtension.entitlements`.)

### Evidence — a third-party project's explicit claim (treat with caution)

**CB Pro Proxy**, `docs/TROLLSTORE_INSTALLATION.md`:

- > "CB Pro Proxy requires **Network Extension entitlements** to create VPN connections. These entitlements cannot be added with:"
  > "- ❌ Free Apple ID (AltStore/Sideloadly)"
  > "- ❌ Standard jailbreak with ideviceinstaller"
  > "- ❌ Unsigned IPA installation methods"
  > "**✅ TrollStore** is the ONLY method that works without a paid Apple Developer account!"
  — https://raw.githubusercontent.com/coolbirdzik/CB-Pro-Proxy/main/docs/TROLLSTORE_INSTALLATION.md

- > "**Why TrollStore works**:"
  > "- TrollStore **fakes** these entitlements during installation"
  > "- iOS accepts them as valid"
  > "- App gets full VPN permissions without Apple signing"
  — https://raw.githubusercontent.com/coolbirdzik/CB-Pro-Proxy/main/docs/TROLLSTORE_INSTALLATION.md

**Caveats I am flagging, not glossing over:**
- This is an **unaffiliated third-party project doc, not official TrollStore documentation.** It is not endorsed or reviewed by opa334.
- Its technical vocabulary is loose ("fakes these entitlements"). TrollStore's documented behaviour is to *preserve* entitlement values that are already in the binary and sign with a fake **root certificate** — the quoted README wording is "preserve the entitlements when resigning them with the fake root certificate on installation."
- The same document instructs users to "TRUST the profile" under Settings → VPN & Device Management, which conflicts with TrollStore's documented model (a footnote in the TrollStore 1.0.8 release notes says it "Pretend[s] apps installed through TrollStore are ad hoc signed"), i.e. TrollStore installs are not provisioning-profile-signed. **This specific step in that guide should be treated as unreliable.**
- Its stated support range "iOS 14.0 - 16.6.1" is a simplification of the real matrix in section 2.

### Evidence — issue-tracker signals (user reports, not documentation)

- TrollStore issue #629 ("Is it currently impossible to use VPN apps in Trollstore 2? ..."):
  > "I have tried using several VPNs with ts 2 (works fine for me) assuming they get entitlements for for creating the VPN profile it should work"
  — comment by `RexRaptor000`, https://github.com/opa334/TrollStore/issues/629#issuecomment-1834428153
  The reporter's own follow-up concluded the failure was **not** TrollStore-related:
  > "Yes, I also found that it is indeed the reason for insufficient cracking permissions, not the IPA dedicated to trolls."
  — comment by `chris7395328`, https://github.com/opa334/TrollStore/issues/629#issuecomment-1835362004
  Issue state: **closed**. No maintainer statement in the thread.

- TrollStore issue #763 contains an install log for a proxy app ("Stash") that TrollStore dumped and processed with the entitlement present:
  > `"com.apple.developer.networking.networkextension" = (`
  > `    "packet-tunnel-provider"`
  > `);`
  > ...
  > `[/private/var/tmp/.../Stash.app/PlugIns/StashTunnel.appex/StashTunnel] Applying CoreTrust bypass...`
  > `[...] Applied CoreTrust bypass!`
  — https://github.com/opa334/TrollStore/issues/763
  **This shows the entitlement is passed through and the tunnel extension is signed, but that install failed with error 185 for an unrelated signing reason — it does NOT demonstrate a working VPN tunnel.** Issue is open.

### Explicitly UNVERIFIED

- **UNVERIFIED:** Any official (opa334) statement that `com.apple.developer.networking.networkextension` works under TrollStore. URL of a source that would settle it: none found.
- **UNVERIFIED:** Any source at all — official or third-party — addressing `com.apple.developer.networking.vpn.api` ("Personal VPN", e.g. `allow-vpn`) under TrollStore.
- **UNVERIFIED:** Any source addressing `NEPacketTunnelProvider` / `NETunnelProviderManager` specifically by class name in a TrollStore context.
- **UNVERIFIED:** Whether the entitlement remains accepted by iOS at *runtime* (as opposed to being preserved in the code signature at install time). No source found that tests and documents this.

---

## 4. The mechanism, as publicly described

**Finding:** All public descriptions are at the level of "an AMFI/CoreTrust signature-verification bug permits entitlements that would otherwise require Apple-issued signing." No exploitation steps are reproduced here (and none are needed for the capability claim).

### Evidence:

- README (current `main`) — the current one-line description of the bug:
  > "It works because of an AMFI/CoreTrust bug where iOS does not correctly verify code signatures of binaries in which there are multiple signers."
  — https://github.com/opa334/TrollStore/blob/main/README.md

- README (1.x / 2.0 era) — the description of the *first* bug:
  > "It works because of an AMFI/CoreTrust bug where iOS does not verify whether or not a root certificate used to sign a binary is legit."
  — https://raw.githubusercontent.com/opa334/TrollStore/1.5.1/README.md · https://raw.githubusercontent.com/opa334/TrollStore/2.0/README.md

- README (current `main`), **Credits and Further Reading** — attribution of the two bugs:
  > "[@alfiecg_dev](https://twitter.com/alfiecg_dev/) - Found the CoreTrust bug that allows TrollStore to work through patchdiffing and worked on automating the bypass."
  > "Google Threat Analysis Group - Found the CoreTrust bug as part of an in-the-wild spyware chain and reported it to Apple."
  > "[@LinusHenze](https://twitter.com/LinusHenze) - Found the installd bypass used to install TrollStore on iOS 14-15.6.1 via TrollHelperOTA, as well as the original CoreTrust bug used in TrollStore 1.0."
  — https://github.com/opa334/TrollStore/blob/main/README.md

- iOS Guide's summary (external documentation):
  > "TrollStore is **not** a jailbreak."
  > "TrollStore is a utility which is able to permanently sign and install any application with almost any entitlement with the help of a CoreTrust bug. The latest releases of TrollStore (specifically 2.0 and later) work through the use of a CoreTrust bug in which code signatures are not correctly verified under certain circumstances."
  — https://ios.cfw.guide/installing-trollstore/

- alfiecg24's deck, describing **CoreTrust** publicly (the component being subverted):
  > "iOS 12 / macOS Mojave introduced CoreTrust, a new code signature verification framework that runs in the kernel before the traditional `amfid` verification in userspace."
  > "on macOS Big Sur / iOS 14 and later, for App Store/Platform apps, CoreTrust *replaces* the amfid verification, speeding up app launches by avoiding a trip into userspace"
  — https://worthdoingbadly.com/coretrust/ (Zhuowei's public write-up of CVE-2022-26766, the *first* CoreTrust bug, patched in iOS 15.5)

- alfiecg24's deck, on the two bypasses and what they yield:
  > "Since iOS 14, there have been two public CoreTrust bypasses"
  > "Used in TrollStore 1.x to support iOS 14.0 - 15.5b4, 15.6 betas"
  > "Used in TrollStore 2.x to support iOS 14.0 - 16.7RC and 17.0"
  > "By creating a crafted code signature with a fake App Store signer, you could bypass CoreTrust" (slide: CVE-2023-41991)
  > "We can permanently install applications with arbitrary entitlements"
  > "TrollStore is an on-device application installer"
  > "It itself is signed with the CoreTrust bypass"
  > "Uses arbitrary entitlements to install new applications like installd"
  > "Uses a 'root helper' to install applications"
  — https://raw.githubusercontent.com/alfiecg24/Presentations/main/The%20State%20of%20iOS%20Jailbreaking%20in%202025.pdf

- **"Permasigning" / no-expiry framing**, official docs:
  > "TrollStore is a permasigned jailed app that can permanently install any IPA you open in it."
  — https://github.com/opa334/TrollStore/blob/main/README.md
  > "permanently sign and install any application with almost any entitlement"
  — https://ios.cfw.guide/installing-trollstore/

---

## 5. Does TrollStore require the app to be already signed, or does it re-sign? Is there a 7-day expiry?

**Finding:** TrollStore **re-signs**. It accepts unsigned IPAs, ad-hoc signs them, and applies the CoreTrust bypass. It skips re-signing in specific documented cases (pre-applied bypass, or already signed with a fake root certificate). It does **not** use a provisioning profile. Official docs describe the result as "permanent"/"permasigned".

### Evidence — TrollStore accepts unsigned IPAs and re-signs them

- alfiecg24's deck, TrollStore app-installations slide:
  > "Accepts unsigned IPA files to be installed"
  > "Signs all MachO files with the CoreTrust bypass"
  > "Copies the bundle to the filesystem"
  > "Creates any necessary containers"
  > "Adds the application to the icon cache"
  — https://raw.githubusercontent.com/alfiecg24/Presentations/main/The%20State%20of%20iOS%20Jailbreaking%20in%202025.pdf

- README — re-signing with entitlement preservation:
  > "and TrollStore will preserve the entitlements when resigning them with the fake root certificate on installation"
  — https://github.com/opa334/TrollStore/blob/main/README.md

- Source code — the signing path and the "sign the entire bundle" step:
  > "// All entitlement related issues should be fixed at this point, so all we need to do is sign the entire bundle"
  > "// And then apply the CoreTrust bypass to all executables"
  — https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m (function `signApp`)

- Release 1.0.7 — behaviour when an app is unsigned and no signer is present:
  > "If ldid is not installed and an app is unsigned, throw an error instead of installing it because it would just crash on launch anyways"
  — https://github.com/opa334/TrollStore/releases/tag/1.0.7

### Evidence — documented cases where TrollStore does *not* re-sign

- Release 1.0.7:
  > "Don't resign an app when the main binary is already signed with a fake root certificate"
  > "Don't resign an app when the Info.plist has a `TSBundlePreSigned` key that's set to `YES`"
  — https://github.com/opa334/TrollStore/releases/tag/1.0.7

- Source code — the pre-applied-exploit fast path (note the literal log strings):
  > "[signApp] taking fast path for app which declares use of a supported pre-applied exploit (%@)"
  > "[signApp] app (%@) declares use of a pre-applied exploit that is not supported on this device. Proceeding to re-sign..."
  > "[signApp] taking fast path for app signed using a custom root certificate (%@)"
  — https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m

- Release 2.0.8 documenting the modern key:
  > "Deprecate TSBundlePreSigned in favour of TSPreAppliedExploitType (1 for signed with old bug, 2 for signed with new bug) TSBundlePreSigned=1 is treated as TSPreAppliedExploitType=1"
  — https://github.com/opa334/TrollStore/releases/tag/2.0.8

### Evidence — no provisioning profile is involved

- Release 1.0.8:
  > "Pretend apps installed through TrollStore are ad hoc signed, not sure if this improves anything but I found some checks for it"
  — https://github.com/opa334/TrollStore/releases/tag/1.0.8

- Source code documents a fallback entitlement set with a **synthetic** team identifier, used when an app ships with no entitlements at all — explicitly described as mimicking what Xcode gives an app:
  > "// In the case where the main executable of the app currently has no entitlements at all"
  > "// We want to ensure it gets signed with fallback entitlements"
  > "// These mimic the entitlements that Xcodes gives every app it signs"
  > `@"application-identifier" : @"TROLLTROLL.*",`
  > `@"com.apple.developer.team-identifier" : @"TROLLTROLL",`
  > `@"get-task-allow" : (__bridge id)kCFBooleanTrue,`
  — https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m

### Evidence — the documented answer on expiry

- The official documentation's answer is **"permanent"**, not a duration:
  > "TrollStore is a permasigned jailed app that can permanently install any IPA you open in it."
  — https://github.com/opa334/TrollStore/blob/main/README.md
  > "permanently sign and install any application with almost any entitlement"
  — https://ios.cfw.guide/installing-trollstore/

- **UNVERIFIED:** an explicit, verbatim "there is no 7-day expiry" statement in TrollStore's own documentation. I searched the README at `main`, `2.0` and `1.5.1`, the full GitHub Releases history, all repository markdown files, and the iOS Guide FAQ (https://ios.cfw.guide/faq/ — which contains no TrollStore section at all). The string "7 day"/"seven day"/"expir" does not occur in TrollStore's docs in a consumer-facing sense; the only match in the repository's source is `kSecCSConsiderExpiration` in `Exploits/fastPathSign/src/codesign.m`, an unrelated codesign flag. The nearest *dated* public statement is about a different product and a different era:
  > "You could use the CoreTrust bug on its own to re-sign your semi-untethered iOS 14 jailbreak app so it wouldn't expire every week."
  — https://worthdoingbadly.com/coretrust/ (July 2022, about Taurine, **not** TrollStore)

---

## 6. Documented limitations — what still does not work even with TrollStore

### 6a. Officially documented: "Banned entitlements" (verbatim from README)

> "### Banned entitlements"
> "iOS 15 on A12+ has banned the following three entitlements related to running unsigned code, these are impossible to get without a PPL bypass, apps signed with them will crash on launch."
> "`com.apple.private.cs.debugger`"
> "`dynamic-codesigning`"
> "`com.apple.private.skip-library-validation`"
— https://github.com/opa334/TrollStore/blob/main/README.md (identical in tags `2.0` and `1.5.1`)

Corroborated by alfiecg24's deck, which also explains what each one grants:
> "Access to almost any entitlement"
> "Three entitlements are restricted to trustcache binaries only on arm64e"
> "com.apple.private.cs.debugger (act as a debugger)"
> "dynamic-codesigning (ability to create proper JIT mappings)"
> "com.apple.private.skip-library-validation (load any library into your process)"
— https://raw.githubusercontent.com/alfiecg24/Presentations/main/The%20State%20of%20iOS%20Jailbreaking%20in%202025.pdf

### 6b. Officially documented: "Things that are not possible using TrollStore" (verbatim from README)

> "### Things that are not possible using TrollStore"
> "- Getting proper platformization (`TF_PLATFORM` / `CS_PLATFORMIZED`)"
> "- Spawning a launch daemon (Would need `CS_PLATFORMIZED`)"
> "- Injecting a tweak into a system process (Would need `TF_PLATFORM`, a userland PAC bypass and a PMAP trust level bypass)"
— https://github.com/opa334/TrollStore/blob/main/README.md

### 6c. Officially documented: entitlements that require Developer Mode (iOS 16+)

Documented in the repository's own source comments and code, not in the README:
> "// On iOS 16+, binaries with certain entitlements requires developer mode to be enabled, so we'll check"
> "// while we're fixing entitlements"
and the corresponding list:
> `@"get-task-allow",`
> `@"task_for_pid-allow",`
> `@"com.apple.system-task-ports",`
> `@"com.apple.system-task-ports.control",`
> `@"com.apple.system-task-ports.token.control",`
> `@"com.apple.private.cs.debugger"`
— https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m

Related confirmed capability: TrollStore itself can enable Developer Mode — release 2.0.9:
> "Add the ability for TrollStore itself to enable developer mode on iOS 16+ (Contributed by @dhinakg)"
— https://github.com/opa334/TrollStore/releases/tag/2.0.9

### 6d. Entitlements that *do* work per official docs (to bound the limitation set)

> "### Unsandboxing"
> "Your app can run unsandboxed using one of the following entitlements:"
> `com.apple.private.security.container-required` / `com.apple.private.security.no-container` / `com.apple.private.security.no-sandbox`
> "You might also need the platform-application entitlement in order for these to work properly"
> "### Root Helpers"
> "you can also spawn binaries as root with the following entitlement: `com.apple.private.persona-mgmt`"
— https://github.com/opa334/TrollStore/blob/main/README.md

App Groups are handled locally by TrollStore: the installer reads `com.apple.security.application-groups` / `com.apple.security.system-groups` from the binary and creates the corresponding group containers itself (`constructGroupsContainersForEntitlements`, `constructTeamIdentifierForEntitlements`) — https://github.com/opa334/TrollStore/blob/main/RootHelper/uicache.m. This is a **source-code observation, not a documented guarantee.**

### 6e. Push notifications

- Maintainer statement (issue #38, "App plugins do not work"):
  > "Yes, we all know this now. I have tried fixing it but not sure what's the problem. Hopefully I will find a fix at some point.
  > EDIT: Notifications work now in 1.0.5. Plugins still don't."
  — opa334, https://github.com/opa334/TrollStore/issues/38
- Matching release note, TrollStore 1.0.5:
  > "Installed apps should now get notification permissions (Notifications work now, but App Plugins still don't, so support is limited) (For already installed apps, just open the IPA in TrollStore once more)"
  — https://github.com/opa334/TrollStore/releases/tag/1.0.5
- **UNVERIFIED:** whether *server-side APNs registration* works for a TrollStore-installed app (i.e. receiving pushes for an app whose `aps-environment` value came from another team's provisioning profile). No official documentation found. The above quotes cover local notification *permissions*, which is a different thing. Relevant observed data point only: issue #763's log shows a dumped `aps-environment = production` entitlement being carried through the install. — https://github.com/opa334/TrollStore/issues/763

### 6f. Community-reported functional limitations (issue tracker — user reports, NOT official documentation)

These are open/closed issues describing behaviour; none is confirmed by the maintainer as an inherent entitlement limitation:

| Issue | Reported behaviour |
|---|---|
| [#215](https://github.com/opa334/TrollStore/issues/215) | "app installed by trollstore can't backup with iCloud" (open) |
| [#180](https://github.com/opa334/TrollStore/issues/180) | "MFMailComposeViewController canSendMail returns NO." — "the same IPA installed with proper method (code signing, Xcode, etc), It works fine." (open) |
| [#478](https://github.com/opa334/TrollStore/issues/478) | "it seems that apps installed with trollstore aren't compatible for the apple watch" (open) |
| [#365](https://github.com/opa334/TrollStore/issues/365) | "Apps installed through TrollStore can't get files through iTunes File Sharing desktop app" (closed) |
| [#750](https://github.com/opa334/TrollStore/issues/750) | "`file system sandbox blocked mmap()` when calling dlopen from unsandboxed app" (closed) |
| [#873](https://github.com/opa334/TrollStore/issues/873) | Widget receives the host app's sandbox path instead of its own (open, TrollStore 2.1) |
| [#752](https://github.com/opa334/TrollStore/issues/752) | Leftover app-extension identifiers block later App Store installs after TrollStore uninstall (closed) |
| [#372](https://github.com/opa334/TrollStore/issues/372) | Apps re-request notification permission after icon-cache rebuild (open) |

### 6g. Entitlements requiring an Apple-issued team ID / provisioning profile / server-side validation

**UNVERIFIED — no explicit TrollStore documentation found.** I searched the README (all tags), the full release history, repository markdown, and the issue tracker for statements of the form "entitlements requiring a provisioning profile / Apple team ID / server-side Apple validation do not work", and found none. What *is* documented is the **inverse**: TrollStore preserves arbitrary entitlements and substitutes a synthetic `TROLLTROLL` team identifier only when an app has no entitlements at all (source quote in 5, above). The ios.cfw.guide hedge — "**almost** any entitlement" (https://ios.cfw.guide/installing-trollstore/) — is the closest thing to an official acknowledgment that a boundary exists, but that documentation **does not enumerate** where the boundary lies.

**UNVERIFIED (secondary, not independently reproduced):** alfiecg24's 2025 deck states, as a platform-limitation bullet in the TrollStore section:
> "Spawning binaries as root is no longer allowed for non-root processes as of iOS 17.6, 18.0"
— https://raw.githubusercontent.com/alfiecg24/Presentations/main/The%20State%20of%20iOS%20Jailbreaking%20in%202025.pdf
This is a *conference deck* claim (recovered by PDF text extraction, not a maintainer statement), and it concerns root-binary spawning rather than an entitlement. It is **outside** the jailed TrollStore range (max iOS 17.0) but **inside** TrollStore Lite's stated range (14.0 – 26.0.1 on jailbroken devices, https://havoc.app/package/trollstorelite). I did not find a TrollStore-side source confirming or denying its effect on TrollStore Lite.

---

## Consolidated list of everything I could NOT source

| # | Claim | Status |
|---|---|---|
| 1 | Official TrollStore statement that `com.apple.developer.networking.networkextension` works | **UNVERIFIED** — key never named in any official doc |
| 2 | Any source at all on `com.apple.developer.networking.vpn.api` / Personal VPN under TrollStore | **UNVERIFIED** — no source found |
| 3 | `NEPacketTunnelProvider` / `NETunnelProviderManager` named in a TrollStore context | **UNVERIFIED** — no source found |
| 4 | Runtime (vs. signature-time) acceptance of the network extension entitlement by iOS under TrollStore | **UNVERIFIED** — no test/documented result found |
| 5 | Explicit verbatim "no 7-day expiry" statement in TrollStore's own docs | **UNVERIFIED** — docs say "permanent"/"permasigned" only |
| 6 | Official enumeration of entitlements that fail because they need a provisioning profile / Apple team ID / server-side validation | **UNVERIFIED** — no such enumeration exists in TrollStore docs |
| 7 | Server-side APNs registration for TrollStore-installed apps | **UNVERIFIED** — only local notification-permission behaviour is documented |
| 8 | iOS 17.6/18.0 root-spawn restriction (alfiecg24 deck) | Recovered from deck PDF text; **not** corroborated by a TrollStore-side source |

## Sources (all URLs cited above)

- https://github.com/opa334/TrollStore · https://github.com/opa334/TrollStore/blob/main/README.md
- https://raw.githubusercontent.com/opa334/TrollStore/2.0/README.md · https://raw.githubusercontent.com/opa334/TrollStore/1.5.1/README.md
- https://github.com/opa334/TrollStore/releases (tags `2.1.1`, `2.1`, `2.0`, `2.0.9`, `2.0.8`, `1.0.8`, `1.0.7`, `1.0.5`)
- https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m · https://github.com/opa334/TrollStore/blob/main/RootHelper/uicache.m · https://github.com/opa334/TrollStore/blob/main/TrollStore/TSAppInfo.m
- https://github.com/opa334/TrollStore/issues/38, /180, /215, /365, /372, /478, /629, /750, /752, /763, /873
- https://ios.cfw.guide/installing-trollstore/ · https://ios.cfw.guide/faq/
- https://havoc.app/package/trollstorelite · https://havoc.app/package/trollstorelite/changes
- https://raw.githubusercontent.com/EasyTier/EasyTier-iOS/main/README.md · https://raw.githubusercontent.com/EasyTier/EasyTier-iOS/main/README_CN.md · https://raw.githubusercontent.com/EasyTier/EasyTier-iOS/main/EasyTierNetworkExtension/EasyTierNetworkExtension.entitlements
- https://raw.githubusercontent.com/coolbirdzik/CB-Pro-Proxy/main/docs/TROLLSTORE_INSTALLATION.md
- https://worthdoingbadly.com/coretrust/
- https://raw.githubusercontent.com/alfiecg24/Presentations/main/The%20State%20of%20iOS%20Jailbreaking%20in%202025.pdf
