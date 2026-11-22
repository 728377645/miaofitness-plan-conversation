#!/bin/bash
# ============================================================================
# 喵喵健身 · iOS IPA 打包脚本
#
# 【本机已验证路径】无参数直接运行即可出包，不需要 Apple 账号、不需要 Team ID：
#     ./build_ipa.sh
#   产出 build/ipa/FitnessPlan.ipa（ad-hoc 自签名，273 KB）
#
# 【正式签名（可选）】传 Team ID 走 Xcode 官方 archive + 导出，可装已注册设备：
#     ./build_ipa.sh <TEAM_ID>
#     IPA_METHOD=ad-hoc ./build_ipa.sh ABCDE12345
#
# 【前置条件】需要完整版 Xcode（含 iPhoneOS SDK）。脚本会自动定位：
#   /Applications/Xcode.app → ~/Applications/Xcode.app → ./Xcode.app
#
# 【图标说明】图标使用 FitnessPlan/Resources/AppIcon.png（普通 PNG），
#   通过 Info.plist 的 CFBundleIconFile 指定。刻意不使用 Assets.xcassets——
#   Xcode 16 对 asset catalog 做设备裁剪时依赖模拟器运行时，
#   在没有安装模拟器的机器上会报 "No available simulator runtimes"。
#
# 【真机安装】ad-hoc 自签名包无法直接装未越狱 iPhone。任选其一：
#   1. 用 Xcode 打开 FitnessPlan.xcodeproj → Signing & Capabilities 登录
#      免费 Apple ID → 选 iPhone → ▶ Run（免费签名 7 天有效，最省事）
#   2. 用 Sideloadly / AltStore 等工具，用免费 Apple ID 对本 IPA 重签名后安装
#   3. 传 Team ID 走正式签名后，用 Finder / Apple Configurator 安装
#
# 【工程结构】
#   FitnessPlan.xcodeproj/             Xcode 工程
#   FitnessPlan/AppDelegate.swift       入口
#   FitnessPlan/ViewController.swift    WKWebView 壳 + JS 桥接 + 弹窗代理
#   FitnessPlan/LocalWebServer.swift    本地静态服务器（页面拥有真实 origin）
#   FitnessPlan/Resources/index.html    内嵌的 App 页面（完整离线可用）
#   FitnessPlan/Resources/AppIcon.png   喵喵健身图标（1024x1024）
#   FitnessPlan/Info.plist              名称 / 权限 / ATS / 状态栏配置
#   build/ipa/FitnessPlan.ipa           输出产物
#
# 【页面适配】
#   - 页面经 http://127.0.0.1:<随机端口> 加载，localStorage 有稳定 origin
#   - confirm / alert / prompt 由原生 UIAlertController 承接
#   - Blob 导出桥接为系统「存储到文件 / 分享」面板
#   - 相机 / 相册权限已在 Info.plist 声明
#   - 数据存于 App 内 localStorage，卸载会清空，请定期导出备份
# ============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PROJECT="FitnessPlan.xcodeproj"
TARGET="FitnessPlan"
CONFIG="Release"
BUILD="$ROOT/build"
OUT="$BUILD/out"
EXPORT="$BUILD/ipa"

TEAM_ID="${1:-${DEVELOPMENT_TEAM:-}}"
METHOD="${IPA_METHOD:-development}"
BUNDLE_ID="${BUNDLE_ID:-com.miaomiao.FitnessPlan}"

# 自动定位 Xcode
if ! xcodebuild -version >/dev/null 2>&1 || xcodebuild -version 2>&1 | grep -q "requires Xcode"; then
  for candidate in /Applications/Xcode.app "$HOME/Applications/Xcode.app" "$ROOT/Xcode.app"; do
    if [[ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      echo "检测到 Xcode: $candidate"
      break
    fi
  done
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "[错误] 没有检测到完整的 Xcode（需要含 iPhoneOS SDK 的完整版，不是 Command Line Tools）。"
  echo "安装 Xcode 16.4 后把 Xcode_16.4.xip 放到 ~/Downloads，运行 ./install_xcode.sh 即可。"
  exit 1
fi

# 检查 iOS SDK
if ! xcodebuild -showsdks 2>/dev/null | grep -q "iphoneos"; then
  echo "[错误] Xcode 已安装但没有 iOS SDK，请先运行：xcodebuild -downloadPlatform iOS"
  exit 1
fi

echo "Xcode: $(xcodebuild -version | head -1)"

# ---------- 路径 A：无 Team ID，直接编译 + ad-hoc 签名出包（本机验证可行）----------
if [[ -z "$TEAM_ID" ]]; then
  echo "[1/4] 编译 Release (arm64, CODE_SIGNING_ALLOWED=NO) ..."
  mkdir -p "$BUILD"
  rm -rf "$OUT" "$BUILD/FitnessPlan.build"
  xcodebuild -project "$PROJECT" -target "$TARGET" \
    -configuration "$CONFIG" -sdk iphoneos \
    CODE_SIGNING_ALLOWED=NO \
    CONFIGURATION_BUILD_DIR="$OUT" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    build > "$BUILD/build.log" 2>&1 || { tail -40 "$BUILD/build.log"; exit 1; }

  echo "[2/4] ad-hoc 签名 ..."
  codesign --force --sign - --timestamp=none \
    --preserve-metadata=entitlements "$OUT/FitnessPlan.app"

  echo "[3/4] 打包 IPA ..."
  rm -rf "$EXPORT"
  mkdir -p "$EXPORT/Payload"
  cp -R "$OUT/FitnessPlan.app" "$EXPORT/Payload/"
  (cd "$EXPORT" && zip -q -r FitnessPlan.ipa Payload)

  echo "[4/4] 校验 ..."
  codesign --verify --deep --strict "$EXPORT/Payload/FitnessPlan.app"
  unzip -t "$EXPORT/FitnessPlan.ipa" >/dev/null

  echo ""
  echo "打包完成: $EXPORT/FitnessPlan.ipa"
  echo "签名方式: ad-hoc（自签名）"
  echo ""
  echo "注意：ad-hoc 包不能直接装未越狱 iPhone。要装真机，任选："
  echo "  1. Xcode 打开工程 → 登录免费 Apple ID → ▶ Run（最省事）"
  echo "  2. Sideloadly / AltStore 用免费 Apple ID 重签名后安装"
  echo "  3. 传 Team ID 重新运行本脚本走正式签名"
  echo ""
  exit 0
fi

# ---------- 路径 B：有 Team ID，走 Xcode 官方归档 + 导出 ----------
ARCHIVE="$BUILD/FitnessPlan.xcarchive"
echo "[1/3] 归档 Release (team=$TEAM_ID) ..."
mkdir -p "$BUILD"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project "$PROJECT" -target "$TARGET" \
  -configuration "$CONFIG" -sdk iphoneos \
  -archivePath "$ARCHIVE" \
  "DEVELOPMENT_TEAM=$TEAM_ID" \
  "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  archive

echo "[2/3] 生成导出配置 ..."
PLIST="$BUILD/ExportOptions.plist"
cp "$ROOT/ExportOptions.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :method $METHOD" "$PLIST"

echo "[3/3] 导出 IPA ..."
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" -exportOptionsPlist "$PLIST" \
  -allowProvisioningUpdates

IPA="$(find "$EXPORT" -maxdepth 1 -name '*.ipa' -print -quit || true)"
[[ -z "$IPA" ]] && { echo "[错误] 未找到导出的 .ipa，请查看上方日志。"; exit 1; }
echo ""
echo "打包完成: $IPA"
echo "安装方式: Xcode → Devices and Simulators → 选设备 → + 选此 IPA；"
echo "          或 Finder / Apple Configurator 拖到已连接设备。"
