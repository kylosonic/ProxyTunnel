#!/usr/bin/env bash
#
# Fetches the tunnel engine into app/libs/.
#
# The AAR is not committed. Two reasons: GitHub's terms are unhappy about binaries
# in source repositories, and a checked-in binary is a binary nobody re-verifies.
# This script pins the exact release and checks the SHA-256 on every build, so a
# replaced or truncated download fails the build instead of shipping.
#
# Verified facts about the pinned artifact (checked against the release, not assumed):
#   * release 2.18.0, asset hev-socks5-tunnel.aar, 590342 bytes
#   * classes.jar contains hev/htproxy/TProxyService.class with
#       TProxyStartService(String, int): boolean
#       TProxyStopService(): boolean
#       TProxyIsRunning(): boolean
#       TProxyGetStats(): long[]
#   * jni/ carries arm64-v8a, armeabi-v7a, x86_64 and x86
#   * its manifest declares minSdkVersion 29, which is why this app's minSdk is 29
#   * licence: MIT
#
# Usage:  android/scripts/fetch-native-libs.sh [destination]
#         destination defaults to android/app/libs

set -euo pipefail

readonly VERSION="2.18.0"
readonly ASSET="hev-socks5-tunnel.aar"
readonly URL="https://github.com/heiher/hev-socks5-tunnel/releases/download/${VERSION}/${ASSET}"
readonly SHA256="15ec8ed121663b562c99caa5bb602d1009f24e5b09e733438b81988f12feaaab"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
destination="${1:-${script_dir}/../app/libs}"
target="${destination}/${ASSET}"

mkdir -p "${destination}"

verify() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "${SHA256}  ${file}" | sha256sum --check --status
  elif command -v shasum >/dev/null 2>&1; then
    local actual
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
    [ "${actual}" = "${SHA256}" ]
  else
    echo "No sha256sum or shasum available; cannot verify the download." >&2
    return 1
  fi
}

if [ -f "${target}" ] && verify "${target}"; then
  echo "hev-socks5-tunnel ${VERSION} already present and verified: ${target}"
  exit 0
fi

echo "Downloading hev-socks5-tunnel ${VERSION} from ${URL}"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl --fail --location --silent --show-error --output "${tmp}" "${URL}"
elif command -v wget >/dev/null 2>&1; then
  wget --quiet --output-document="${tmp}" "${URL}"
else
  echo "Neither curl nor wget is available." >&2
  exit 1
fi

if ! verify "${tmp}"; then
  echo "SHA-256 mismatch for ${URL}" >&2
  echo "Expected: ${SHA256}" >&2
  echo "This is not a transient error. The artifact is not what this project was" >&2
  echo "built and tested against; refusing to use it." >&2
  exit 1
fi

mv "${tmp}" "${target}"
trap - EXIT
echo "Verified and installed: ${target}"
echo "SHA-256: ${SHA256}"
