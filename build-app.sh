#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/ModuleCacheNetworkPortEval
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx26.0" -module-cache-path "$PWD/.build/ModuleCacheNetworkPortEval" Sources/NetworkPortEval/*.swift -o .build/NetworkPortEval
BIN="$PWD/.build"
APP_NAME="${APP_BUNDLE_NAME:-NetworkPortEval}"
APP="$PWD/$APP_NAME.app"
APP_IDENTIFIER="${APP_BUNDLE_ID:-com.networkporteval.desktop}"
APP_VERSION="${APP_SHORT_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD_VERSION:-6}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NetworkPortEval" "$APP/Contents/MacOS/NetworkPortEval"
ICONSET="$PWD/.build/NetworkPortEvalBundle.iconset"
mkdir -p "$ICONSET"
for ENTRY in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  SIZE="${ENTRY%% *}"
  NAME="${ENTRY#* }"
  sips -z "$SIZE" "$SIZE" Resources/AppIcon.png --out "$ICONSET/icon_${NAME}.png" >/dev/null
done
python3 - "$ICONSET" "$APP/Contents/Resources/AppIcon.icns" <<'PY'
import pathlib, struct, sys
iconset, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
representations = [("icp4", "16x16.png"), ("icp5", "32x32.png"), ("icp6", "32x32@2x.png"), ("ic07", "128x128.png"), ("ic08", "256x256.png"), ("ic09", "512x512.png"), ("ic10", "512x512@2x.png")]
chunks = []
for code, name in representations:
    data = (iconset / f"icon_{name}").read_bytes()
    chunks.append(code.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NetworkPortEval</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleIdentifier</key><string>$APP_IDENTIFIER</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Baptiste CRESTANI / BC performances</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleSignature</key><string>????</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$APP_BUILD</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Test the TCP and UDP network destinations you import.</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>fr</string><string>de</string><string>it</string><string>es</string><string>pt</string><string>zh-Hans</string><string>ja</string></array>
</dict></plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
for LANGUAGE in en fr de it es pt zh-Hans ja; do mkdir -p "$APP/Contents/Resources/$LANGUAGE.lproj"; done
printf '%s\n' '"NSLocalNetworkUsageDescription" = "Test the TCP and UDP network destinations you import.";' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
printf '%s\n' '"NSLocalNetworkUsageDescription" = "Tester les destinations réseau TCP et UDP que vous importez.";' > "$APP/Contents/Resources/fr.lproj/InfoPlist.strings"
printf '%s\n' '"NSLocalNetworkUsageDescription" = "Die importierten TCP- und UDP-Netzwerkziele testen.";' > "$APP/Contents/Resources/de.lproj/InfoPlist.strings"
printf '%s\n' '"NSLocalNetworkUsageDescription" = "Testare le destinazioni di rete TCP e UDP importate.";' > "$APP/Contents/Resources/it.lproj/InfoPlist.strings"
printf '%s\n' '"NSLocalNetworkUsageDescription" = "Probar los destinos de red TCP y UDP importados.";' > "$APP/Contents/Resources/es.lproj/InfoPlist.strings"
printf '%s\n' '"NSLocalNetworkUsageDescription" = "Testar os destinos de rede TCP e UDP importados.";' > "$APP/Contents/Resources/pt.lproj/InfoPlist.strings"
printf '%s\n' '"NSLocalNetworkUsageDescription" = "测试导入的 TCP 和 UDP 网络目标。";' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
printf '%s\n' '"NSLocalNetworkUsageDescription" = "読み込んだ TCP および UDP のネットワーク宛先をテストします。";' > "$APP/Contents/Resources/ja.lproj/InfoPlist.strings"
if [[ -n "${APP_PROVISIONING_PROFILE:-}" ]]; then
  cp "$APP_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi
xattr -cr "$APP"
# File-provider-backed workspace folders can reattach metadata to the bundle
# root after the recursive clear; strip those root attributes explicitly.
xattr -c "$APP" 2>/dev/null || true
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
codesign_app() {
  if [[ -n "${APP_ENTITLEMENTS:-}" ]]; then
    codesign "$@" --entitlements "$APP_ENTITLEMENTS"
  else
    codesign "$@"
  fi
}
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  # Local and CI development builds stay ad-hoc signed and are not suitable
  # for Gatekeeper-approved distribution.
  codesign_app --force --deep --sign - "$APP"
else
  # Developer ID releases require the hardened runtime and a secure timestamp
  # so Apple can notarize the app. This app has no special runtime entitlements.
  codesign_app --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
SIGNED=0
for ATTEMPT in 1 2 3; do
  xattr -c "$APP" 2>/dev/null || true
  if codesign --verify --deep --strict "$APP"; then SIGNED=1; break; fi
  sleep 0.2
done
test "$SIGNED" -eq 1
printf 'Built: %s\n' "$APP"
