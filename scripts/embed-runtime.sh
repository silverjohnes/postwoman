#!/usr/bin/env bash
# Puts Node.js and Newman inside the app bundle and signs the node helper.
# Usage: embed-runtime.sh <Postwoman.app> <codesign identity | -> [--no-sign]
# Used by scripts/build-app.sh and by the Xcode "Embed runtime" build phase (project.yml).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?path to Postwoman.app}"
SIGN="${2:--}"
VENDOR="$ROOT/Vendor"
NODE_TGZ="$(ls "$VENDOR"/node-bin-darwin-arm64-*.tgz | head -1)"
NEWMAN_TGZ="$VENDOR/newman-runtime.tgz"

# the archives must be exactly what update-runtime.sh recorded
( cd "$VENDOR" && if command -v shasum >/dev/null; then shasum -a 512 -c SHA512SUMS --quiet; else sha512sum -c SHA512SUMS --quiet; fi ) \
  || { echo "Vendor/ checksum mismatch — run scripts/update-runtime.sh or restore the files" >&2; exit 1; }

RES="$APP/Contents/Resources"; HELP="$APP/Contents/Helpers"
mkdir -p "$RES" "$HELP"

# newman: a tree of plain JavaScript files → Contents/Resources/newman/node_modules/newman
rm -rf "$RES/newman"
tar -xzf "$NEWMAN_TGZ" -C "$RES"                       # archive root is "newman/"
[[ -f "$RES/newman/node_modules/newman/package.json" ]] || { echo "newman missing after extraction" >&2; exit 1; }

# node: the unmodified official binary from the npm package → Contents/Helpers/node
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tar -xzf "$NODE_TGZ" -C "$TMP" package/bin/node package/LICENSE
cp "$TMP/package/bin/node" "$HELP/node"; chmod 755 "$HELP/node"
cp "$TMP/package/LICENSE" "$RES/NODE-LICENSE.txt"

if [[ "${3:-}" != "--no-sign" ]]; then
  TS="--timestamp"; [[ "$SIGN" == "-" ]] && TS="--timestamp=none"
  codesign --force --options runtime "$TS" --entitlements "$ROOT/Resources/Node.entitlements" --sign "$SIGN" "$HELP/node"
  echo "  node signed (sandbox-inherit)"
fi
echo "  embedded: $(du -sh "$RES/newman" | cut -f1) newman, $(du -sh "$HELP/node" | cut -f1) node"
