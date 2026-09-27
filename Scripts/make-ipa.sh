#!/usr/bin/env bash
#
#  make-ipa.sh
#  Packages an unsigned .app (plus its embedded .appex) into ProxyTunnel.ipa.
#
#  An IPA is nothing more than a ZIP with a single top-level directory named
#  `Payload` containing the .app. No signing is involved, which is exactly the
#  point: the artifact this produces is then signed by whatever tool the user
#  chooses (Sideloadly, AltStore, …).
#
#  Usage:
#      Scripts/make-ipa.sh <path-to-.app> <output.ipa>
#
set -euo pipefail

APP_PATH="${1:-}"
OUTPUT_IPA="${2:-ProxyTunnel.ipa}"

if [[ -z "$APP_PATH" ]]; then
  echo "usage: $0 <path-to-.app> <output.ipa>" >&2
  exit 2
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: '$APP_PATH' is not a directory. Did the build produce an .app?" >&2
  exit 1
fi

APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
OUTPUT_IPA="$(cd "$(dirname "$OUTPUT_IPA")" 2>/dev/null && pwd || echo "$(pwd)")/$(basename "$OUTPUT_IPA")"

APP_NAME="$(basename "$APP_PATH")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Staging $APP_NAME"
mkdir -p "$STAGE/Payload"
# `ditto` preserves symlinks, permissions and extended attributes the way the
# rest of Apple's tooling expects; `cp -R` does not always.
ditto "$APP_PATH" "$STAGE/Payload/$APP_NAME"

echo "==> Removing code-signing artefacts so the IPA is provably unsigned"
# A clean CODE_SIGNING_ALLOWED=NO build produces none of these. Removing them
# anyway means the artifact cannot accidentally ship a signature or a
# provisioning profile that belongs to somebody's developer account.
while IFS= read -r -d '' item; do
  echo "    removing $(basename "$item")"
  rm -rf "$item"
done < <(find "$STAGE/Payload" \
           \( -name "_CodeSignature" -o -name "embedded.mobileprovision" -o -name "*.mobileprovision" \) \
           -print0 2>/dev/null || true)

echo "==> Writing $OUTPUT_IPA"
rm -f "$OUTPUT_IPA"
( cd "$STAGE" && zip -q -r -y "$OUTPUT_IPA" Payload )

SIZE="$(stat -f%z "$OUTPUT_IPA" 2>/dev/null || stat -c%s "$OUTPUT_IPA")"
echo "==> Done: $OUTPUT_IPA ($(echo "$SIZE" | awk '{ printf "%.1f MiB", $1/1048576 }'))"

shasum -a 256 "$OUTPUT_IPA" | awk '{ print "    sha256 " $1 }'
