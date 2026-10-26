#!/bin/bash
# Builds the release binary and packs it into a .mcpb Claude extension bundle.
#
# An .mcpb is a zip with manifest.json at its root. There is no dependency on the
# `mcpb` CLI here: zip is enough, and it keeps the toolchain to what macOS ships.
set -euo pipefail

NAME="apple-system-mcp"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The installer keys on the manifest version alone. A new build under an unchanged version
# makes it conclude the extension is already installed, and its only offer is "Uninstall".
# Fail here, before building, if the three places that carry the version disagree.
MANIFEST_VERSION="$(python3 -c "import json; print(json.load(open('extension/manifest.json'))['version'])")"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
CODE_VERSION="$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/SystemMCPCore/Server.swift)"
if [ "$MANIFEST_VERSION" != "$PLIST_VERSION" ] || [ "$MANIFEST_VERSION" != "$CODE_VERSION" ]; then
  echo "!! version mismatch: manifest=$MANIFEST_VERSION plist=$PLIST_VERSION server=$CODE_VERSION" >&2
  exit 1
fi
echo "==> Version $MANIFEST_VERSION"

# Apple silicon only. A universal build (--arch arm64 --arch x86_64) doubles the bundle
# and takes ~70x longer to link, and macOS 26 is the end of the road for Intel anyway.
echo "==> Building $NAME (arm64)"
swift build -c release

BINARY=".build/release/$NAME"
[ -f "$BINARY" ] || { echo "!! no release binary found" >&2; exit 1; }

# GUARD: Apple silicon only. A stray extra architecture would otherwise ship without
# any error.
ARCHS="$(lipo -archs "$BINARY")"
[ "$ARCHS" = "arm64" ] \
  || { echo "!! expected arm64 only, got: $ARCHS" >&2; exit 1; }

# The embedded Info.plist gives the binary its bundle identifier, which the signature's
# designated requirement quotes. This server reads no TCC-protected location, so there
# are no usage descriptions to look for.
echo "==> Checking the embedded Info.plist survived linking"
otool -P "$BINARY" | grep -q "codes.eneko.$NAME" \
  || { echo "!! Info.plist missing from $BINARY" >&2; exit 1; }

echo "==> Staging bundle"
STAGE="$ROOT/extension"
rm -rf "$STAGE/server"
mkdir -p "$STAGE/server"
cp "$BINARY" "$STAGE/server/$NAME"
chmod +x "$STAGE/server/$NAME"

# Re-sign. The signature `swift build` leaves is flagged `linker-signed`, which macOS
# treats as signed by nobody: it carries no designated requirement. A real identity gives
# the binary a stable identity across rebuilds; ad-hoc (the default here) gives a new
# cdhash every time. Set MCPB_SIGN_IDENTITY to a signing identity to avoid that.
IDENTITY="${MCPB_SIGN_IDENTITY:--}"
echo "==> Signing with identity: $IDENTITY"

# The identifier is pinned rather than inferred, because the designated requirement
# quotes it and an inferred one would depend on how the binary was built. Keep it in step
# with CFBundleIdentifier in Resources/Info.plist.
SIGN_ARGS=(--force --identifier "codes.eneko.$NAME" --sign "$IDENTITY")

# Hardened runtime is off by default: it is required for notarisation only. Opt in with
# MCPB_HARDENED=1 when preparing something to distribute. This server sends no Apple
# events and needs no entitlements file.
if [ "${MCPB_HARDENED:-0}" = "1" ]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$STAGE/server/$NAME"
FLAGS=$(codesign -dv "$STAGE/server/$NAME" 2>&1 | grep -oE 'flags=[^ ]*' || true)
case "$FLAGS" in
  *linker-signed*) echo "!! still linker-signed ($FLAGS)" >&2; exit 1 ;;
  *) echo "    $FLAGS" ;;
esac

# Signing rewrites the binary, so re-check the plist rather than trusting the earlier pass.
otool -P "$STAGE/server/$NAME" | grep -q "codes.eneko.$NAME" \
  || { echo "!! Info.plist lost during signing" >&2; exit 1; }

python3 -c "import json,sys; json.load(open('$STAGE/manifest.json'))" \
  || { echo "!! manifest.json is not valid JSON" >&2; exit 1; }

echo "==> Designated requirement"
codesign -d -r- "$STAGE/server/$NAME" 2>&1 | grep "^designated" | sed 's/^/    /' \
  || echo "    (none — ad-hoc signature; the identity changes on every rebuild)"

echo "==> Packing"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/$NAME.mcpb"
rm -f "$OUT"
# -X drops resource forks and extra attributes; the archive should contain only what
# the manifest describes.
( cd "$STAGE" && zip -qrX "$OUT" manifest.json icon.png server )

# The MCPB spec does not say whether the installer preserves the executable bit, so
# verify the archive at least records it. If a future Claude release drops it, the
# symptom is a server that never starts, and the fix is a chmod +x on the installed copy.
echo "==> Verifying the executable bit survived"
MODE=$(unzip -Z "$OUT" "server/$NAME" | awk 'NR==1 {print $1}')
case "$MODE" in
  *x*) echo "    mode $MODE — executable" ;;
  *)   echo "!! executable bit lost: $MODE" >&2; exit 1 ;;
esac

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install it by opening the file with Claude, then quit Claude Desktop completely and"
echo "reopen it: installing does not restart a server process that is already running."
