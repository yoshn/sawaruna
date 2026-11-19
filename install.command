#!/bin/zsh
# Sawaruna installer: builds the app from the source in this folder, on your own Mac.
# Sawaruna インストーラー：このフォルダのソースから、あなたのMacの上でアプリを作ります。
set -e
cd "$(dirname "$0")"
echo "== Installing Sawaruna / Sawaruna をインストールします =="

# Developer tools (Xcode Command Line Tools) / 開発ツールの確認
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Command Line Tools are missing. Click \"Install\" in the dialog, then run this file again."
  echo "開発ツールがありません。表示されるダイアログで「インストール」を押し、終わったらもう一度このファイルを開いてください。"
  xcode-select --install || true
  exit 1
fi

# Build in a temporary folder first, so a failed build never breaks an installed copy
# まず別の場所でビルドする（失敗しても、いま入っているアプリは壊さない）
BUILD="$(mktemp -d)"
if ! xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sawaruna.swift -o "$BUILD/Sawaruna" 2> build.log; then
  cat build.log
  rm -rf "$BUILD"
  echo ""
  echo "Build failed. Nothing was changed. Details are in build.log."
  echo "ビルドに失敗しました。何も変更していません。詳しくは build.log を見てください。"
  exit 1
fi

pkill -x Sawaruna 2>/dev/null || true

APP="$HOME/Applications/Sawaruna.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Localizations.json "$APP/Contents/Resources/Localizations.json"
if [ -d Sawaruna.iconset ]; then
  iconutil -c icns Sawaruna.iconset -o "$APP/Contents/Resources/Sawaruna.icns" || true
fi
cp "$BUILD/Sawaruna" "$APP/Contents/MacOS/Sawaruna"
rm -rf "$BUILD"

# Sign with Hardened Runtime, which stops other programs from injecting into Sawaruna
# and misusing its Input Monitoring or camera permission.
# Hardened Runtime を付けて署名する（ほかのプログラムが入り込んで許可を悪用するのを防ぐ）
codesign --force --options runtime --entitlements Sawaruna.entitlements -s - "$APP"

# A rebuilt app cannot reuse old permissions, so reset them and let the app ask again
# ビルドし直すと以前の許可が使えなくなるので、許可をリセットして案内し直す
tccutil reset ListenEvent com.sawaruna.app >/dev/null 2>&1 || true
tccutil reset Camera com.sawaruna.app >/dev/null 2>&1 || true
touch "$APP"

echo ""
echo "Installed: $APP"
echo "インストール完了: $APP"
open "$APP"
