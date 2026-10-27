#!/usr/bin/env bash
# Refreshes Vendor/ from the npm registry (needed only to UPDATE the embedded runtime; building the app uses no network):
#   Vendor/newman-runtime.tgz                    Newman + production dependencies, pure JavaScript (no native addons), without .bin/.map
#   Vendor/node-bin-darwin-arm64-<ver>.tgz       the official Node.js binary for macOS arm64, the original npm package
#   Vendor/SHA512SUMS                            checked by scripts/embed-runtime.sh on every build
#   NEWMAN_VERSION=6.2.3 NODE_VERSION=22.22.0 bash scripts/update-runtime.sh
set -euo pipefail
cd "$(dirname "$0")/.."
NEWMAN_VERSION="${NEWMAN_VERSION:-6.2.3}"
NODE_VERSION="${NODE_VERSION:-22.22.0}"
command -v npm >/dev/null || { echo "npm is required (only for this script)" >&2; exit 1; }
VENDOR="$PWD/Vendor"; mkdir -p "$VENDOR"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "▸ newman $NEWMAN_VERSION"
mkdir -p "$WORK/newman"
cat > "$WORK/newman/package.json" <<JSON
{ "name": "postwoman-newman-runtime", "version": "1.0.0", "private": true, "dependencies": { "newman": "$NEWMAN_VERSION" } }
JSON
( cd "$WORK/newman" && npm install --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error )
# a signed app bundle must not contain symlinks (node_modules/.bin); source maps are dead weight
find "$WORK/newman/node_modules" -name .bin -type d -prune -exec rm -rf {} +
find "$WORK/newman/node_modules" -name '*.map' -type f -delete
[ -z "$(find "$WORK/newman/node_modules" -type l)" ] || { echo "symlinks left in node_modules" >&2; exit 1; }
[ -z "$(find "$WORK/newman/node_modules" \( -name '*.node' -o -name '*.dylib' \))" ] || { echo "native addon found: it would need its own code signature" >&2; exit 1; }
tar --sort=name --mtime='2020-01-01' --owner=0 --group=0 --numeric-owner -czf "$VENDOR/newman-runtime.tgz" -C "$WORK" newman

echo "▸ node $NODE_VERSION (macOS arm64)"
rm -f "$VENDOR"/node-bin-darwin-arm64-*.tgz
( cd "$VENDOR" && npm pack "node-bin-darwin-arm64@$NODE_VERSION" --loglevel=error >/dev/null )

( cd "$VENDOR" && { if command -v shasum >/dev/null; then shasum -a 512 *.tgz; else sha512sum *.tgz; fi; } > SHA512SUMS )
ls -lh "$VENDOR"
echo "✔ Vendor/ updated"
