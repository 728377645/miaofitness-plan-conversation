#!/bin/bash
# 从 ~/Downloads/Xcode_*.xip 解压并部署 Xcode。
# 不需要 sudo：优先放 /Applications，没权限就放 ~/Applications，
# 之后用 DEVELOPER_DIR 环境变量指向它即可正常编译 iOS App。
set -euo pipefail

XIP="${1:-}"
if [[ -z "$XIP" ]]; then
  XIP="$(find "$HOME/Downloads" -maxdepth 1 -iname 'Xcode_*.xip' -print -quit 2>/dev/null || true)"
fi
if [[ -z "$XIP" || ! -f "$XIP" ]]; then
  echo "未找到安装包。请先在 Apple Developer 下载 Xcode 16.4.xip 到 ~/Downloads"
  echo "下载页：https://developer.apple.com/downloads/?q=Xcode%2016.4"
  exit 1
fi

echo "找到安装包: $XIP ($(du -h "$XIP" | awk '{print $1}'))"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/xcode_extract.XXXXXX")"
echo "解压到: $WORK"
(cd "$WORK" && xip --expand "$XIP")

APP="$(find "$WORK" -maxdepth 3 -name 'Xcode.app' -type d -print -quit)"
if [[ -z "$APP" ]]; then
  echo "解压后未找到 Xcode.app"
  exit 1
fi

TARGET="/Applications/Xcode.app"
if [[ -e "$TARGET" ]]; then
  echo "$TARGET 已存在，本次不覆盖"
else
  if mv "$APP" "$TARGET" 2>/dev/null; then
    echo "已安装到 $TARGET"
  else
    mkdir -p "$HOME/Applications"
    TARGET="$HOME/Applications/Xcode.app"
    rm -rf "$TARGET"
    mv "$APP" "$TARGET"
    echo "无系统目录写权限，已安装到 $TARGET"
  fi
fi

DEV="$TARGET/Contents/Developer"
echo ""
echo "验证 Xcode："
DEVELOPER_DIR="$DEV" xcodebuild -version
echo ""
echo "后续编译请带上：export DEVELOPER_DIR=$DEV"
