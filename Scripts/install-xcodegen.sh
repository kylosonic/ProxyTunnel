#!/usr/bin/env bash
#
#  install-xcodegen.sh
#  Installs XcodeGen, which turns project.yml into ProxyTunnel.xcodeproj.
#
#  Two independent paths, because a CI machine that cannot install a build tool
#  is a bad reason for a build to fail:
#
#    1. Homebrew, which is preinstalled on GitHub's macOS runners.
#    2. A pinned release binary from the XcodeGen GitHub releases, checked against
#       a SHA-256 recorded here.
#
#  The repository deliberately does not commit a .xcodeproj: it would carry
#  machine-specific absolute paths and produce unmergeable conflicts. Generating
#  it is a two-second, deterministic step.
#
set -euo pipefail

# Pinned so the build is reproducible. Bump deliberately.
XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.44.1}"
XCODEGEN_SHA256="${XCODEGEN_SHA256:-}"

echo "==> Looking for XcodeGen"

if command -v xcodegen >/dev/null 2>&1; then
  echo "    already installed: $(xcodegen --version)"
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  echo "==> Installing XcodeGen with Homebrew"
  # `brew install` is verbose and slow to update itself; the CI log is easier to
  # read without the auto-update chatter.
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen
  if command -v xcodegen >/dev/null 2>&1; then
    echo "    installed: $(xcodegen --version)"
    exit 0
  fi
  echo "    Homebrew install did not put xcodegen on PATH; falling back to a release binary"
fi

echo "==> Downloading XcodeGen ${XCODEGEN_VERSION} release binary"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
curl --fail --location --silent --show-error --output "$WORK/xcodegen.zip" "$URL"

if [[ -n "$XCODEGEN_SHA256" ]]; then
  ACTUAL="$(shasum -a 256 "$WORK/xcodegen.zip" | awk '{print $1}')"
  if [[ "$ACTUAL" != "$XCODEGEN_SHA256" ]]; then
    echo "SHA-256 mismatch: expected ${XCODEGEN_SHA256}, got ${ACTUAL}" >&2
    exit 1
  fi
  echo "    checksum verified"
else
  echo "    NOTE: no XCODEGEN_SHA256 pinned for this version; the download was not verified."
  echo "          Set XCODEGEN_SHA256 in the environment to enable verification."
fi

unzip -q "$WORK/xcodegen.zip" -d "$WORK"
BIN="$(find "$WORK" -type f -name xcodegen -perm +111 | head -n 1)"
if [[ -z "$BIN" ]]; then
  # Some releases ship the binary inside a .build directory without the
  # executable bit set.
  BIN="$(find "$WORK" -type f -name xcodegen | head -n 1)"
  chmod +x "$BIN"
fi

DEST="${RUNNER_TOOL_CACHE:-$HOME/.local}/xcodegen/bin"
mkdir -p "$DEST"
cp "$BIN" "$DEST/xcodegen"
chmod +x "$DEST/xcodegen"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$DEST" >> "$GITHUB_PATH"
fi

echo "    installed to $DEST"
"$DEST/xcodegen" --version
