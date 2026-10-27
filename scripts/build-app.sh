#!/usr/bin/env bash
# Builds build/Postwoman.app without opening Xcode (needs Xcode or the Command Line Tools).
#   scripts/build-app.sh                  Apple Silicon (arm64), ad-hoc signature
#   scripts/build-app.sh --sign "Developer ID Application: Name (TEAMID)"
#   scripts/build-app.sh --run            launch the app afterwards
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=Postwoman
OUT=build
APP="$OUT/$APP_NAME.app"
ARCHS=(arm64)                    # the bundled node is arm64; macOS 27 runs on Apple Silicon only
SIGN="-"
RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) SIGN="${2:?--sign needs an identity}"; shift ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

SDK="$(xcrun --sdk macosx --show-sdk-path)"
rm -rf "$APP" "$OUT/obj" "$OUT/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/obj"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)
echo "▸ compiling ${#SOURCES[@]} files for: ${ARCHS[*]}"
for A in "${ARCHS[@]}"; do
  xcrun swiftc -O -parse-as-library -swift-version 5 -module-name "$APP_NAME" \
    -target "$A-apple-macos15.0" -sdk "$SDK" "${SOURCES[@]}" -o "$OUT/obj/$APP_NAME-$A"
done
if [[ ${#ARCHS[@]} -gt 1 ]]; then
  lipo -create "$OUT"/obj/"$APP_NAME"-* -output "$APP/Contents/MacOS/$APP_NAME"
else
  cp "$OUT/obj/$APP_NAME-${ARCHS[0]}" "$APP/Contents/MacOS/$APP_NAME"
fi

echo "▸ bundling resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Resources/runner.js "$APP/Contents/Resources/runner.js"
# interface languages: Resources/Localization/<lang>.lproj/Localizable.strings → binary .strings (also validates the syntax)
for L in Resources/Localization/*.lproj; do
  mkdir -p "$APP/Contents/Resources/$(basename "$L")"
  plutil -convert binary1 -o "$APP/Contents/Resources/$(basename "$L")/Localizable.strings" "$L/Localizable.strings"
done
cp -R Resources/Assets.xcassets/AppIcon.appiconset "$OUT/AppIcon.iconset"
rm -f "$OUT/AppIcon.iconset/Contents.json"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ embedding node + newman"
bash "$(dirname "$0")/embed-runtime.sh" "$APP" "$SIGN"

echo "▸ signing (${SIGN/#-/ad-hoc})"
TS="--timestamp"; [[ "$SIGN" == "-" ]] && TS="--timestamp=none"
# the app itself last: its seal covers the already signed helper
codesign --force --options runtime "$TS" --entitlements Resources/Postwoman.entitlements --sign "$SIGN" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "✔ $APP"
[[ $RUN -eq 1 ]] && open "$APP"
exit 0
