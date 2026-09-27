# Building

Nothing here requires a Mac you own.

---

## On GitHub Actions (the intended path)

Push to `master`, or trigger it manually:

**Actions ▸ Build iOS IPA ▸ Run workflow**

### Inputs

| Input | Default | Notes |
|---|---|---|
| `bundle_id` | `io.github.kylosonic.proxytunnel` | **Change this.** Free Apple ID signing registers App IDs globally |
| `configuration` | `Release` | `Debug` also works and builds faster |
| `run_tests` | `true` | Runs the simulator test suite |

### Artifacts

| Artifact | Contents |
|---|---|
| `ProxyTunnel-iOS-unsigned` | `ProxyTunnel.ipa`, `sha256.txt`, `provenance.txt`, `validation.txt` |
| `ProxyTunnel-iOS-build-logs` | `build-app.txt`, `build-extension.txt`, `tests.txt`, `TestResults.xcresult`, `toolchain.txt`, `schemes.txt`, `simulators.txt`, `xcodegen.txt`, `package.txt` |

### What the job does

1. Checks out the repository.
2. Prints the toolchain — `xcodebuild -version`, SDK versions, `swift --version`,
   installed Xcodes — into the log artifact. When a build breaks after a runner
   image update, this is the first thing to look at.
3. Installs XcodeGen (Homebrew, falling back to a pinned release binary).
4. Generates `ProxyTunnel.xcodeproj` from `project.yml`.
5. Resolves Swift package dependencies. There are none outside the local package,
   so this is instant and needs no network — but it is an explicit step so that a
   future remote dependency fails here with a clear message rather than in the
   middle of the build.
6. Builds the **app target** (which embeds the extension) unsigned.
7. Builds the **extension target** standalone unsigned.
8. Picks an available iOS simulator and runs the test suite.
9. Packages `ProxyTunnel.ipa`.
10. Validates the IPA's structure and fails the run if anything is wrong.
11. Uploads both artifacts and writes a summary to the run page.

> Steps 6, 7 and 8 each run with `if: always()`. A failure in one does not hide
> the errors in the others, which matters a great deal when each macOS runner
> minute is expensive. A final step turns their outcomes back into the job's
> pass/fail.

### Runner images

The workflow uses `macos-15`, which provides Xcode 16.x.

To use a different image, change `runs-on`:

```yaml
runs-on: macos-14    # also Xcode 16.x
runs-on: macos-13    # Xcode 15.x — the Package.swift tools version still works
```

Nothing in the project depends on a specific Xcode version beyond Swift 5.9 (the
package tools version) and the iOS 16 deployment target.

### Actions minutes

macOS runners are billed at a **10× multiplier**. GitHub Free includes 2,000
minutes/month across all runners, which is roughly **200 real macOS minutes** —
about 15–20 builds of this project.

Public repositories get unlimited free minutes on standard runners. That is why
this repository is public.

---

## On a Mac

```bash
brew install xcodegen
xcodegen generate
open ProxyTunnel.xcodeproj
```

Then set your team in **Signing & Capabilities** if you have a paid account, or
leave signing off for a simulator build.

### Build and package by hand

```bash
xcodebuild build \
  -project ProxyTunnel.xcodeproj \
  -scheme ProxyTunnel \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

./Scripts/make-ipa.sh \
  build/DerivedData/Build/Products/Release-iphoneos/ProxyTunnel.app \
  ProxyTunnel.ipa

./Scripts/validate-ipa.sh ProxyTunnel.ipa io.github.kylosonic.proxytunnel
```

### Run the tests

```bash
xcodebuild test \
  -project ProxyTunnel.xcodeproj \
  -scheme ProxyTunnelCoreTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

---

## Why there is no `.xcodeproj` in the repository

`ProxyTunnel.xcodeproj` is **generated** from [`project.yml`](../project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen), and it is in `.gitignore`.

Three reasons:

1. **No machine-specific paths in version control.** A committed `.pbxproj` picks
   up absolute paths from whoever last opened it.
2. **No merge conflicts.** `.pbxproj` is a large, ordered, UUID-keyed file that
   conflicts unhelpfully when two people add a file.
3. **Reproducibility.** A CI machine with nothing installed but Xcode and
   XcodeGen produces exactly the same project every time.

The trade-off is one extra command, `xcodegen generate`, which the workflow runs
for you.

### What `project.yml` declares

```
ProxyTunnel                 application      Sources/ProxyTunnelApp
ProxyTunnelExtension        app-extension    Sources/ProxyTunnelExtension
ProxyTunnelCoreTests        bundle.unit-test Tests/ProxyTunnelCoreTests

packages:
  ProxyTunnelCore           path: Packages/ProxyTunnelCore   (static library)
```

Signing settings in `project.yml` are intentionally **empty**:
`DEVELOPMENT_TEAM: ""`, `PROVISIONING_PROFILE_SPECIFIER: ""`. The unsigned CI
build passes `CODE_SIGNING_ALLOWED=NO` on the command line, and a developer with
a paid account picks their own team in Xcode. **No certificate, profile, team
identifier or password is committed anywhere.**

---

## Changing the bundle identifier

`BUNDLE_ID_BASE` is defined once in `project.yml`:

```yaml
settings:
  base:
    BUNDLE_ID_BASE: io.github.kylosonic.proxytunnel
```

Everything derives from it:

| Target | Bundle identifier |
|---|---|
| App | `$(BUNDLE_ID_BASE)` |
| Extension | `$(BUNDLE_ID_BASE).tunnel` |
| Tests | `$(BUNDLE_ID_BASE).tests` |
| App Group | `group.$(BUNDLE_ID_BASE)` |

Three ways to change it, in order of preference:

1. Edit `project.yml` and commit. Simplest and most permanent.
2. Pass it at build time:
   ```bash
   xcodebuild ... BUNDLE_ID_BASE=com.yourname.proxytunnel
   ```
   The workflow does exactly this from its `bundle_id` input.
3. Set it in Sideloadly's bundle-ID field. **Not recommended** — Sideloadly may
   rewrite the app's identifier without rewriting the extension's or the App
   Group's, and the resulting mismatch is confusing. The app is written to
   tolerate it (it discovers the extension's real identifier at runtime), and it
   will fall back to an inline credential if the App Group stops matching, but
   setting it upfront is cleaner.

---

## Environment variables the scripts understand

| Variable | Used by | Purpose |
|---|---|---|
| `XCODEGEN_VERSION` | `Scripts/install-xcodegen.sh` | Pin a XcodeGen release (default `2.44.1`) |
| `XCODEGEN_SHA256` | `Scripts/install-xcodegen.sh` | Verify the downloaded binary; unset by default, and the script says so |

`Scripts/make-ipa.sh` and `Scripts/validate-ipa.sh` take positional arguments and
read no environment.

---

## Adding a dependency

Prefer not to. If you must:

```yaml
# project.yml
packages:
  SomePackage:
    url: https://github.com/example/SomePackage
    from: 1.2.3
```

and add it to the relevant target's `dependencies`. Then make sure it builds on a
GitHub-hosted macOS runner with no manual setup — a dependency that needs a
Homebrew formula, a prebuilt binary, or a configured keychain is not a dependency
this project can accept.

For a **local** package like `ProxyTunnelCore`, the `path:` form is used, which
resolves offline and needs no `Package.resolved`.

---

## Reproducing a CI failure locally

Every build step's output is in the `ProxyTunnel-iOS-build-logs` artifact and is
plain `xcodebuild` output. To reproduce:

1. Download the artifact.
2. Find the first `error:` in the relevant `build-*.txt`.
3. Run the same command from the log locally (or on a Mac in the cloud), changing
   only `-derivedDataPath`.

The `provenance.txt` file records the commit, the runner image, Xcode version,
configuration and bundle identifier, so a build is traceable to the code that
produced it.

---

## Troubleshooting the build itself

| Symptom | Cause | Fix |
|---|---|---|
| `xcodegen: command not found` | Homebrew install failed and the release download did not reach `GITHUB_PATH` | Check `xcodegen.txt` in the log artifact; set `XCODEGEN_SHA256` if your network rewrites downloads |
| `no such module 'ProxyTunnelCore'` | The package path in `project.yml` does not match the directory | It must be `Packages/ProxyTunnelCore` |
| `Signing for "ProxyTunnel" requires a development team` | A signing setting leaked into the project | The build must pass `CODE_SIGNING_ALLOWED=NO`; do not add a team to `project.yml` |
| `Cannot find a simulator named …` | The runner image changed its device list | The workflow picks a device dynamically; if you hardcoded one, remove it |
| `The operation could not be completed` during `xcodebuild test` | Simulator failed to boot | Re-run; the log artifact's `simulators.txt` shows what was available |
| Unresolved package `ProxyTunnelCore` | The generated project is stale | Delete `ProxyTunnel.xcodeproj` and re-run `xcodegen generate` |
