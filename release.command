#!/bin/zsh
# Build a signed, notarized Sawaruna.dmg for distribution.
# 配布用の Sawaruna.dmg を作る（Developer ID で署名し、Apple の公証を通す）
#
# One-time setup / 最初に一度だけ:
#   1. A "Developer ID Application" certificate in your keychain
#   2. xcrun notarytool store-credentials sawaruna-notary --apple-id <Apple ID> --team-id <Team ID>
set -e
cd "$(dirname "$0")"
PROFILE="${NOTARY_PROFILE:-sawaruna-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
OUT="$HOME/dev/sawaruna-release"
mkdir -p "$OUT"

# 1) Find the Developer ID certificate / 署名に使う証明書を探す
ID="$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ {print $2; exit}')"
NAME="$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application' | sed -E 's/.*"(.*)"/\1/')"
if [ -z "$ID" ]; then
  echo "No \"Developer ID Application\" certificate was found in your keychain."
  echo "「Developer ID Application」の証明書がキーチェーンにありません。最初の準備を先に行ってください。"
  exit 1
fi
echo "Signing as / 署名: $NAME"

# 2) Build for Apple silicon and Intel, then join them / 両方のMac向けに作って1つにまとめる
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" Sawaruna.swift -o "$WORK/Sawaruna-$ARCH"
done
lipo -create "$WORK/Sawaruna-arm64" "$WORK/Sawaruna-x86_64" -output "$WORK/Sawaruna"

# 3) Assemble the app / アプリの形にする
APP="$WORK/stage/Sawaruna.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Localizations.json "$APP/Contents/Resources/"
iconutil -c icns Sawaruna.iconset -o "$APP/Contents/Resources/Sawaruna.icns"
cp "$WORK/Sawaruna" "$APP/Contents/MacOS/Sawaruna"

xattr -cr "$APP"
# 4) Sign with Hardened Runtime and a secure timestamp / 署名する
codesign --force --options runtime --timestamp --entitlements Sawaruna.entitlements --sign "$ID" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

# 5) Make the disk image / ディスクイメージを作る
ln -s /Applications "$WORK/stage/Applications"
DMG="$OUT/Sawaruna-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Sawaruna" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO "$DMG"
codesign --force --timestamp --sign "$ID" "$DMG"

# 6) Notarize and staple / Apple の公証を受けて、結果を貼り付ける
echo "Sending to Apple for notarization (a few minutes) / Apple の公証を待っています（数分）"
RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$WORK/notary.log")"
if ! print -r -- "$RESULT" | grep -q "status: Accepted"; then
  SUB="$(print -r -- "$RESULT" | grep -m1 -E '^ *id:' | awk '{print $2}')"
  echo "Notarization was not accepted. Details: xcrun notarytool log $SUB --keychain-profile $PROFILE"
  echo "公証が通りませんでした。上のコマンドで理由を表示できます。"
  exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# 7) Check that Gatekeeper accepts it / 警告なしで開けるか確かめる
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
spctl --assess --type execute --verbose=4 "$APP"
(cd "$OUT" && shasum -a 256 "${DMG:t}") | tee "$DMG.sha256"
echo ""
echo "Done / 完成: $DMG"
