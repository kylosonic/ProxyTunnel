#!/usr/bin/env bash
#
#  validate-ipa.sh
#  Inspects the packaged IPA and asserts the things §15 of the specification asks
#  for. Everything it checks is printed, so the CI log is itself a report.
#
#  Exit code 0 means every hard check passed. Any failure is printed with the
#  word FAIL and aborts the run — a green build that produced an unusable IPA
#  would be worse than a red one.
#
#  Usage:
#      Scripts/validate-ipa.sh <path-to.ipa> [expected-app-bundle-id]
#
set -uo pipefail

IPA="${1:-ProxyTunnel.ipa}"
EXPECTED_APP_ID="${2:-}"

FAILURES=0
APP_NAME=""
APP_ID=""
APPEX_NAME=""
APPEX_PATH=""
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
info() { printf '  ----  %s\n' "$1"; }
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

head2 "1. The file itself"

if [[ -f "$IPA" ]]; then
  pass "IPA exists: $IPA"
else
  fail "IPA not found: $IPA"
  exit 1
fi

SIZE="$(stat -f%z "$IPA" 2>/dev/null || stat -c%s "$IPA")"
if [[ "$SIZE" -gt 100000 ]]; then
  pass "IPA size is plausible: $SIZE bytes"
else
  fail "IPA is suspiciously small: $SIZE bytes"
fi

info "sha256 $(shasum -a 256 "$IPA" | awk '{print $1}')"
info "file type: $(file -b "$IPA")"

head2 "2. ZIP integrity"

if unzip -tqq "$IPA" >/dev/null 2>&1; then
  pass "ZIP central directory and CRCs are valid"
else
  fail "ZIP is corrupt (unzip -t failed)"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -qq "$IPA" -d "$WORK"

head2 "3. Bundle structure"

if [[ -d "$WORK/Payload" ]]; then
  pass "Payload/ exists"
else
  fail "Payload/ is missing — this is not a valid IPA"
  exit 1
fi

APP_COUNT="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | wc -l | tr -d ' ')"
if [[ "$APP_COUNT" == "1" ]]; then
  APP_PATH="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | head -n 1)"
  APP_NAME="$(basename "$APP_PATH")"
  pass "Exactly one .app: $APP_NAME"
else
  fail "Expected exactly one .app in Payload/, found $APP_COUNT"
  exit 1
fi

head2 "4. Main executable"

APP_BINARY="$APP_PATH/${APP_NAME%.app}"
if [[ -f "$APP_BINARY" ]]; then
  pass "Main executable exists: ${APP_NAME%.app}"
  info "architectures: $(lipo -archs "$APP_BINARY" 2>/dev/null || echo 'lipo failed')"
  if lipo -archs "$APP_BINARY" 2>/dev/null | grep -q arm64; then
    pass "Binary contains arm64 (required for a physical device)"
  else
    fail "Binary does not contain arm64 — it cannot run on an iPhone"
  fi
else
  fail "Main executable missing at $APP_BINARY"
fi

if [[ -f "$APP_PATH/Info.plist" ]]; then
  pass "App Info.plist exists"
  APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || echo '')"
  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist" 2>/dev/null || echo '')"
  APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist" 2>/dev/null || echo '')"
  info "CFBundleIdentifier: ${APP_ID:-<unreadable>}"
  info "CFBundleShortVersionString: ${APP_VERSION:-<unreadable>} (build ${APP_BUILD:-?})"
  if [[ -n "$APP_ID" ]]; then
    pass "App bundle identifier is set"
  else
    fail "App bundle identifier is empty"
  fi
  if [[ -n "$EXPECTED_APP_ID" && "$APP_ID" != "$EXPECTED_APP_ID" ]]; then
    fail "App bundle identifier is '$APP_ID' but '$EXPECTED_APP_ID' was expected"
  fi
else
  fail "App Info.plist is missing"
  APP_ID=""
fi

head2 "5. Packet Tunnel Provider extension"

PLUGINS="$APP_PATH/PlugIns"
if [[ -d "$PLUGINS" ]]; then
  pass "PlugIns/ exists"
else
  fail "PlugIns/ is missing — the packet tunnel extension was not embedded"
fi

APPEX_PATH="$(find "$APP_PATH/PlugIns" -maxdepth 1 -name '*.appex' 2>/dev/null | head -n 1)"
if [[ -n "$APPEX_PATH" && -d "$APPEX_PATH" ]]; then
  APPEX_NAME="$(basename "$APPEX_PATH")"
  pass "Extension bundle exists: $APPEX_NAME"

  APPEX_BINARY="$APPEX_PATH/${APPEX_NAME%.appex}"
  if [[ -f "$APPEX_BINARY" ]]; then
    pass "Extension executable exists: ${APPEX_NAME%.appex}"
    info "architectures: $(lipo -archs "$APPEX_BINARY" 2>/dev/null || echo 'lipo failed')"
  else
    fail "Extension executable missing at $APPEX_BINARY"
  fi

  if [[ -f "$APPEX_PATH/Info.plist" ]]; then
    APPEX_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPEX_PATH/Info.plist" 2>/dev/null || echo '')"
    POINT="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$APPEX_PATH/Info.plist" 2>/dev/null || echo '')"
    PRINCIPAL="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' "$APPEX_PATH/Info.plist" 2>/dev/null || echo '')"
    PKG_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$APPEX_PATH/Info.plist" 2>/dev/null || echo '')"

    info "extension CFBundleIdentifier: ${APPEX_ID:-<unreadable>}"
    info "NSExtensionPointIdentifier: ${POINT:-<unreadable>}"
    info "NSExtensionPrincipalClass: ${PRINCIPAL:-<unreadable>}"
    info "CFBundlePackageType: ${PKG_TYPE:-<unreadable>}"

    if [[ "$POINT" == "com.apple.networkextension.packet-tunnel" ]]; then
      pass "Extension point is com.apple.networkextension.packet-tunnel"
    else
      fail "Extension point is '$POINT' — iOS will not offer this as a packet tunnel"
    fi

    if [[ -n "$PRINCIPAL" ]]; then
      pass "NSExtensionPrincipalClass is declared"
    else
      fail "NSExtensionPrincipalClass is missing"
    fi

    if [[ "$PKG_TYPE" == "XPC!" ]]; then
      pass "Extension package type is XPC!"
    else
      fail "Extension package type is '$PKG_TYPE', expected 'XPC!'"
    fi

    if [[ -n "$APP_ID" && -n "$APPEX_ID" ]]; then
      case "$APPEX_ID" in
        "$APP_ID".*) pass "Extension identifier '$APPEX_ID' is prefixed by the app identifier" ;;
        *)           fail "Extension identifier '$APPEX_ID' is not a child of '$APP_ID'" ;;
      esac
    fi
  else
    fail "Extension Info.plist is missing"
  fi
else
  fail "No .appex found inside PlugIns/"
fi

head2 "6. No signing material or credentials shipped"

for pattern in '*.mobileprovision' '*.provisionprofile' '*.p12' '*.pfx' '*.p8' '*.key' '*.pem' 'AuthKey_*'; do
  FOUND="$(find "$WORK/Payload" -name "$pattern" -print 2>/dev/null | head -n 5)"
  if [[ -n "$FOUND" ]]; then
    fail "Found signing material matching '$pattern': $FOUND"
  else
    pass "No files matching '$pattern'"
  fi
done

SIG_DIRS="$(find "$WORK/Payload" -name '_CodeSignature' -type d -print 2>/dev/null | head -n 5)"
if [[ -n "$SIG_DIRS" ]]; then
  fail "Found _CodeSignature directories, so this build is not unsigned: $SIG_DIRS"
else
  pass "No _CodeSignature directories — the build really is unsigned"
fi

head2 "7. Code signature state (informational)"

if codesign --verify "$APP_PATH" >/dev/null 2>&1; then
  fail "codesign reports a valid signature; the artifact was supposed to be unsigned"
else
  pass "codesign reports no valid signature, as expected for an unsigned build"
  info "codesign output: $(codesign --verify --verbose=2 "$APP_PATH" 2>&1 | head -n 2 | tr '\n' ' ')"
fi

for bundle in "$APP_PATH" "$APPEX_PATH"; do
  [[ -z "$bundle" || ! -d "$bundle" ]] && continue
  info "entitlements of $(basename "$bundle"):"
  if ENT="$(codesign -d --entitlements :- "$bundle" 2>/dev/null)" && [[ -n "$ENT" ]]; then
    printf '%s\n' "$ENT" | sed 's/^/          /'
  else
    info "          (none — an unsigned binary carries no embedded entitlements)"
  fi
done

head2 "8. Credential scan inside the shipped bundle"

# The app has no hard-coded credentials, but check rather than assert.
SUSPECT="$(grep -rIl --binary-files=without-match -E 'proxy-password-[0-9a-f]{8}|"(password|passwd)"[[:space:]]*:[[:space:]]*"[^"]+"' "$WORK/Payload" 2>/dev/null | head -n 5)"
if [[ -n "$SUSPECT" ]]; then
  fail "Possible hard-coded credential in: $SUSPECT"
else
  pass "No hard-coded credential patterns found in the bundle's text files"
fi

head2 "9. Summary"

info "App:        ${APP_NAME}"
info "App ID:     ${APP_ID:-unknown}"
info "Extension:  ${APPEX_NAME:-missing}"
info "Size:       $(echo "$SIZE" | awk '{ printf "%.1f MiB", $1/1048576 }')"

if [[ "$FAILURES" -eq 0 ]]; then
  printf '\n\033[32mAll validation checks passed.\033[0m\n'
  exit 0
fi

printf '\n\033[31m%d validation check(s) FAILED.\033[0m\n' "$FAILURES"
exit 1
