#!/bin/zsh
# build.sh — 编译 TempBar 并打包成可分发的 .app
#
# 为什么不用 Xcode 工程：这个 App 没有任何资源文件、没有 storyboard、
# 不需要 App Group 或付费证书，一个 swiftc 命令就能出成品，
# 分发时同事拿到的就是一个可双击的 .app，不用装 Xcode。
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/build/TempBar.app"
SRC="$ROOT/Sources"

echo "==> 清理"
rm -rf "$ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译（arm64 + x86_64 通用二进制）"
# 先编当前架构。要出 Intel 版本的话，下面这行加 -target x86_64-apple-macos13.0
# 然后 lipo 合并即可；同事都是 Apple Silicon 就先省这一步。
swiftc \
  -O \
  -whole-module-optimization \
  -target arm64-apple-macos13.0 \
  -framework Cocoa \
  -framework CoreBluetooth \
  -framework UserNotifications \
  -framework ServiceManagement \
  -o "$APP/Contents/MacOS/TempBar" \
  "$SRC"/*.swift

echo "==> 生成图标"
# 图标是脚本画出来的（make-icon.py），不依赖设计稿也不往仓库里塞二进制。
# Finder/Dock 里没图标的 app 会显示成一块白色占位，看着像没做完的半成品，
# 所以哪怕只是临时图标也要有。
python3 "$ROOT/make-icon.py" >/dev/null
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> 拷入 Info.plist"
# bundle id 带版本号：每次给同事发新版都改这里。
# 原因：ad-hoc 签名每次重建都会变，macOS 的 TCC 会把"签名变了"当成
# "这不是同一个 app"，于是保留旧的授权记录但拒绝新的调用，
# 结果就是 SIGABRT："attempted to access privacy-sensitive data
# without a usage description"——明明 Info.plist 里有那个键。
# 换一个新 id 让系统重新弹一次授权，比让用户去手动删 TCC 记录可靠。
BUNDLE_ID="local.tempbar.app.v3"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TempBar</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>TempBar</string>
  <key>CFBundleDisplayName</key><string>TempBar 温度</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.5</string>
  <key>CFBundleVersion</key><string>7</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>需要蓝牙权限，用于被动接收温湿度计的 BTHome 广播。仅监听广播，不会连接或配对设备，也不影响温度计电池。</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>需要蓝牙权限，用于被动接收温湿度计的 BTHome 广播。</string>
  <key>NSHumanReadableCopyright</key><string>TempBar</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <!-- 更新源是那台开发机的裸 IP + 非标端口，没有证书，只能走 http。
         ATS 默认会拦掉，所以这里放开；安全性由下载后强制校验 sha256 兜底
         （见 Updater.swift，校验不过直接中止，不解压更不替换）。 -->
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
  <key>NSUpdateFeedURL</key><string>http://36.111.167.161:8888/tempbar/updates.json</string>
</dict>
</plist>
PLIST

echo "==> 签名（本地 ad-hoc）"
# ad-hoc 签名足够让 TCC 采信 Info.plist 里的蓝牙用途声明。
# 没签名的话蓝牙授权弹窗根本不会出现，系统直接 SIGABRT。
codesign -f -s - --deep "$APP"
plutil -lint "$APP/Contents/Info.plist"

echo ""
echo "完成：$APP"
echo "架构：$(lipo -archs "$APP/Contents/MacOS/TempBar")"
echo "大小：$(du -sh "$APP" | cut -f1)"
