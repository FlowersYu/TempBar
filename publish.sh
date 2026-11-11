#!/bin/zsh
# publish.sh — 打包并把新版本推到更新服务器
#
# 用法：
#   ./publish.sh                        # 用默认更新说明
#   ./publish.sh "修了小号排版"          # 带一句更新说明
#
# 做的事：编译打包 → 算 sha256 → 生成 updates.json → 上传 → 验证能下载。
# 同事那边点「检查更新」拿到的就是这里推上去的东西。
set -e
cd "$(dirname "$0")"

# 服务器地址不写在仓库里（仓库是公开的），
# 放在同目录的 publish.env 中，参考 publish.env.example。 
if [ -f "./publish.env" ]; then
  source ./publish.env
fi
SERVER="${TEMPBAR_SERVER:?没有配置服务器地址。复制 publish.env.example 为 publish.env 并填好 TEMPBAR_SERVER}"
REMOTE="${TEMPBAR_REMOTE:-/var/www/tempbar}"
BASE_URL="${TEMPBAR_BASE_URL:?没有配置下载地址，请在 publish.env 里设置 TEMPBAR_BASE_URL}"
NOTES="${1:-常规更新}"

# 先编译。package.sh 只负责打包，不会重新编译 ——
# 少了这一步就会把上一次的旧二进制推上去，
# 表现是"改了代码、也发了版，但同事更新完还是老样子"（第一次推的时候踩过）。
./build.sh
./package.sh

PLIST="build/TempBar.app/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
ZIP="dist/TempBar.zip"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
SIZE=$(stat -f%z "$ZIP")

cat > dist/updates.json <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "publishedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "notes": "$NOTES",
  "downloadURL": "$BASE_URL/TempBar.zip",
  "size": $SIZE,
  "sha256": "$SHA"
}
JSON

echo "==> 上传 $VERSION (build $BUILD)  $(( SIZE / 1024 ))K"
scp -q -o LogLevel=ERROR "$ZIP" "$SERVER:$REMOTE/TempBar.zip"
scp -q -o LogLevel=ERROR dist/updates.json "$SERVER:$REMOTE/updates.json"
# 权限要分开设：目录必须带 x（755），否则 nginx 进不去，
# 表现是网页正常但所有图片 403。
# 之前这里写的是 chmod 644 $REMOTE/*，连目录一起 644 了，
# 结果每发一次版就把 assets 目录的可执行位抹掉一次。
ssh -o LogLevel=ERROR "$SERVER" \
  "find $REMOTE -type d -exec chmod 755 {} + && find $REMOTE -type f -exec chmod 644 {} + && ls -lh $REMOTE"

echo ""
echo "==> 验证"
curl -s --max-time 8 "$BASE_URL/updates.json" | python3 -m json.tool
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE_URL/TempBar.zip")
echo "包下载状态码：$CODE（200 才正常）"
[ "$CODE" = "200" ] && echo "推送完成，同事点「检查更新」就能拿到 $VERSION"
