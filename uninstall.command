#!/bin/zsh
# Sawaruna をアンインストールする（撮った写真は消しません）
pkill -x Sawaruna 2>/dev/null
rm -rf "$HOME/Applications/Sawaruna.app"
rm -f "$HOME/.sawaruna-debug" "$HOME/Library/Logs/sawaruna.log"
defaults delete com.sawaruna.app 2>/dev/null
tccutil reset ListenEvent com.sawaruna.app 2>/dev/null
tccutil reset Camera com.sawaruna.app 2>/dev/null
echo "Sawaruna を削除しました。"
echo "撮った写真は「ピクチャ/Sawaruna」に残っています。不要なら、そのフォルダをゴミ箱に入れてください。"
