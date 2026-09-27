# Signed builds (when you have an Apple Developer Program membership)

Nothing in this repository requires a paid account to **build**, and the unsigned
workflow never reads a signing secret.

If you obtain a membership, this is what to add. **There are no placeholder or
fake values anywhere in the repository, and there should not be** — add the
secrets to GitHub and paste the job below.

---

## What a paid membership actually buys you

One thing that matters here: the **Network Extensions** capability becomes
self-service. No request form, no approval process. Apple DTS:

> In Nov 2016 this policy changed for Network Extension providers. Any developer
> can now use the Network Extension provider capability like they would any other
> capability.

Tick "Network Extensions" in Xcode for both targets, and the tunnel works.

Full analysis: [`ENTITLEMENTS-AND-SIGNING.md`](ENTITLEMENTS-AND-SIGNING.md).

---

## Repository secrets to create

**Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret**

| Secret | What it is | How to produce it |
|---|---|---|
| `APPLE_TEAM_ID` | Your 10-character Team ID | <https://developer.apple.com/account> ▸ Membership details ▸ Team ID |
| `SIGNING_CERTIFICATE` | Base64 of a `.p12` containing your **Apple Development** or **Apple Distribution** certificate and its private key | Keychain Access ▸ export the certificate as `.p12`, then `base64 -i Certificates.p12 \| pbcopy` |
| `SIGNING_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` | — |
| `PROVISIONING_PROFILE` | Base64 of a `.mobileprovision` that includes the **Network Extensions** capability and covers **both** bundle identifiers | Create two App IDs (app and `.tunnel`), enable Network Extensions on both, then create a development or ad-hoc profile for each and combine; or let `xcodebuild -allowProvisioningUpdates` manage it |
| `KEYCHAIN_PASSWORD` | Any random string; it only protects the temporary keychain on the runner | `openssl rand -base64 32` |

> **A profile must cover the extension too.** The extension is a separate bundle
> identifier and needs its own App ID with Network Extensions enabled. A profile
> that only covers the app will produce an app that installs and whose extension
> fails to launch — the same outcome as a free account, from a self-inflicted
> cause.

### Do not commit any of these

`.gitignore` already excludes `*.p12`, `*.mobileprovision`, `*.cer`, `*.p8`,
`*.pem`, `*.key`, `secrets/` and `signing/`. Keep it that way. Nothing in this
project needs a certificate in the tree.

---

## The job to add

Paste this into [`.github/workflows/build-ipa.yml`](../.github/workflows/build-ipa.yml)
as a second job, alongside `build`. It is deliberately separate: the unsigned job
must keep working for people without an account.

```yaml
  build-signed:
    name: Build signed IPA
    runs-on: macos-15
    timeout-minutes: 75
    # Only run when the secrets exist, so a fork or a fresh clone is unaffected.
    if: ${{ github.event_name == 'workflow_dispatch' && secrets.SIGNING_CERTIFICATE != '' }}
    needs: build

    steps:
      - name: Check out the repository
        uses: actions/checkout@v4

      - name: Install XcodeGen
        run: |
          set -euo pipefail
          chmod +x Scripts/*.sh
          ./Scripts/install-xcodegen.sh

      - name: Generate the Xcode project
        run: xcodegen generate --spec project.yml --project .

      # ── Keychain ─────────────────────────────────────────────────────────
      # A GitHub runner starts with no usable signing keychain. Create a
      # throwaway one, import the certificate into it, and make it the default
      # for this job only.
      - name: Create a temporary keychain and import the certificate
        env:
          SIGNING_CERTIFICATE: ${{ secrets.SIGNING_CERTIFICATE }}
          SIGNING_CERTIFICATE_PASSWORD: ${{ secrets.SIGNING_CERTIFICATE_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          set -euo pipefail
          KEYCHAIN_PATH="$RUNNER_TEMP/signing.keychain-db"
          CERT_PATH="$RUNNER_TEMP/certificate.p12"

          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
          security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

          echo -n "$SIGNING_CERTIFICATE" | base64 --decode > "$CERT_PATH"
          security import "$CERT_PATH" \
            -P "$SIGNING_CERTIFICATE_PASSWORD" \
            -A -t cert -f pkcs12 \
            -k "$KEYCHAIN_PATH"
          security set-key-partition-list \
            -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

          # Put our keychain first so codesign finds it without a search list.
          security list-keychain -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')
          security find-identity -v -p codesigning "$KEYCHAIN_PATH"

          rm -f "$CERT_PATH"

      # ── Provisioning profiles ────────────────────────────────────────────
      # One profile per bundle identifier. The extension's is what carries the
      # Network Extension entitlement, and it is the one that actually matters.
      - name: Install the provisioning profiles
        env:
          PROVISIONING_PROFILE: ${{ secrets.PROVISIONING_PROFILE }}
        run: |
          set -euo pipefail
          PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
          mkdir -p "$PROFILES_DIR"

          # A JSON array of base64 profiles keeps this generic: one entry per
          # bundle identifier (app and extension).
          echo -n "$PROVISIONING_PROFILE" | base64 --decode > "$RUNNER_TEMP/profiles.tar.gz"
          tar -xzf "$RUNNER_TEMP/profiles.tar.gz" -C "$PROFILES_DIR"
          ls -la "$PROFILES_DIR"
          rm -f "$RUNNER_TEMP/profiles.tar.gz"

      - name: Build and archive, signed
        env:
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          BUNDLE_ID_BASE: ${{ github.event.inputs.bundle_id || 'io.github.kylosonic.proxytunnel' }}
        run: |
          set -euo pipefail
          set -o pipefail
          mkdir -p artifacts/logs

          xcodebuild archive \
            -project ProxyTunnel.xcodeproj \
            -scheme ProxyTunnel \
            -configuration Release \
            -destination 'generic/platform=iOS' \
            -archivePath build/ProxyTunnel.xcarchive \
            -allowProvisioningUpdates \
            DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
            CODE_SIGN_STYLE=Manual \
            BUNDLE_ID_BASE="$BUNDLE_ID_BASE" \
            2>&1 | tee artifacts/logs/archive.txt

      - name: Export the signed IPA
        env:
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
        run: |
          set -euo pipefail
          set -o pipefail
          cat > build/ExportOptions.plist <<PLIST
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>method</key>
            <string>development</string>
            <key>teamID</key>
            <string>${APPLE_TEAM_ID}</string>
            <key>signingStyle</key>
            <string>manual</string>
            <key>stripSwiftSymbols</key>
            <true/>
            <key>compileBitcode</key>
            <false/>
            <key>destination</key>
            <string>export</string>
          </dict>
          </plist>
          PLIST

          xcodebuild -exportArchive \
            -archivePath build/ProxyTunnel.xcarchive \
            -exportOptionsPlist build/ExportOptions.plist \
            -exportPath build/export \
            -allowProvisioningUpdates \
            2>&1 | tee artifacts/logs/export.txt

          mv build/export/*.ipa ProxyTunnel-signed.ipa

      - name: Verify that the extension really is entitled
        run: |
          set -euo pipefail
          ./Scripts/validate-ipa.sh ProxyTunnel-signed.ipa "$BUNDLE_ID_BASE" \
            2>&1 | tee artifacts/logs/validation-signed.txt

          # The unsigned build asserts "no signature". A signed build asserts the
          # opposite, and specifically that the entitlement survived.
          unzip -qq ProxyTunnel-signed.ipa -d build/signed-ipa
          APPEX="$(find build/signed-ipa/Payload -name '*.appex' | head -n 1)"
          echo "Checking $APPEX"
          codesign -d --entitlements :- "$APPEX" | tee artifacts/logs/extension-entitlements.txt
          if ! grep -q 'com.apple.developer.networking.networkextension' artifacts/logs/extension-entitlements.txt; then
            echo "::error::The extension was signed WITHOUT the Network Extension entitlement. The tunnel will not start."
            exit 1
          fi
          echo "Extension carries the Network Extension entitlement."

      - name: Clean up the keychain
        if: always()
        run: security delete-keychain "$RUNNER_TEMP/signing.keychain-db" || true

      - name: Upload the signed IPA
        uses: actions/upload-artifact@v4
        with:
          name: ProxyTunnel-iOS-signed
          path: |
            ProxyTunnel-signed.ipa
            artifacts/logs/validation-signed.txt
            artifacts/logs/extension-entitlements.txt

      - name: Upload the signed build logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: ProxyTunnel-iOS-signed-build-logs
          path: artifacts/logs
```

---

## Notes on the job above

**`PROVISIONING_PROFILE` is a tarball.** Because two profiles are needed (app and
extension), the secret holds a base64-encoded `.tar.gz` of both `.mobileprovision`
files. Export them from the developer portal, tar them, then:

```bash
base64 -i profiles.tar.gz | pbcopy
```

**`method: development`** produces an IPA installable on registered devices. For
TestFlight or the App Store, change it to `app-store` — and note that a
Network-Extension app submitted to the App Store goes through stricter validation,
including the requirement that *both* bundles carry the entitlement.

**`-allowProvisioningUpdates`** lets `xcodebuild` create or update profiles. If
you would rather manage them by hand, drop the flag and set
`PROVISIONING_PROFILE_SPECIFIER` per target instead.

**The verification step is the important one.** Signing can succeed while the
entitlement is silently missing — that is the failure mode this whole project is
documented around. The job therefore reads the entitlements back out of the
signed `.appex` and **fails the build** if the Network Extension entitlement is
not there. A green signed build means a tunnel that can actually start.

**The `if:` guard** means the job only runs on a manual dispatch and only when the
certificate secret exists. A fork, a fresh clone, or a contributor without an
account is unaffected.

---

## After installing a signed build

1. Install the IPA (Sideloadly in "normal install" mode, Apple Configurator, or
   `xcrun devicectl`).
2. Open the app → **Settings ▸ Diagnostics ▸ Signing & entitlements**. The
   extension profile should now list
   `com.apple.developer.networking.networkextension: packet-tunnel-provider`, and
   the verdict should read "The packet tunnel extension has the required
   entitlement".
3. Add your proxy and tap **Test connection** to confirm the proxy works.
4. Tap **CONNECT**. iOS will ask for permission the first time —
   *"ProxyTunnel" Would Like to Add VPN Configurations* — and then the tunnel
   starts.
5. Verify it is really carrying traffic: the Connect screen shows live counters
   reported by the extension. **If `tcpConnectionsOpened` stays at zero while you
   browse, the tunnel is not carrying anything**, whatever the status light says.
   That is the check that distinguishes a working tunnel from a plausible-looking
   one.

If the tunnel starts but nothing loads, check the extension's log
(**Settings ▸ Logs ▸ Show the extension's log**), which is mirrored into the App
Group container.
