#!/bin/bash
# 用法：
#   ./build.sh            编译打包到 build/MenuBar.app
#   ./build.sh install    编译后安装到 /Applications 并启动
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MenuBar"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
MIN_OS="13.0"

mkdir -p "$BUILD_DIR"

# 1. 图标（只生成一次）
if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> 生成图标"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift Tools/make_icon.swift "$BUILD_DIR/icon_1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD_DIR/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$BUILD_DIR/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$ICONSET" "$BUILD_DIR/icon_1024.png"
fi

# 2. 编译（arm64 + x86_64 通用二进制）
echo "==> 编译"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "$ARCH-apple-macos$MIN_OS" -sdk "$SDK" \
    Sources/*.swift -o "$BUILD_DIR/$APP_NAME-$ARCH"
done

# 3. 打包 .app
echo "==> 打包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rm -f "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64"

# 4. 签名
# 用项目目录里一个固定的自签名证书签名，系统就能认出每次编译出来的是「同一个 App」，
# 辅助功能权限在重新编译后依然有效。证书放在独立的钥匙串文件里，不碰登录钥匙串。
SIGN_DIR="$PWD/.signing"
SIGN_KEYCHAIN="$SIGN_DIR/signing.keychain-db"
SIGN_PASS="menubar-local-signing"     # 只用于这个本地钥匙串
SIGN_NAME="MenuBar Local Signing"

create_signing_identity() {
  echo "==> 首次编译：生成本地签名证书"
  mkdir -p "$SIGN_DIR"
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $SIGN_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  # 用系统自带的 LibreSSL，它导出的 p12 能被 security 正常导入
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$SIGN_DIR/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$SIGN_DIR/cert.pem" \
    -out "$tmp/id.p12" -passout "pass:$SIGN_PASS" -name "$SIGN_NAME"
  security create-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN"
  security set-keychain-settings "$SIGN_KEYCHAIN"          # 不自动上锁
  security unlock-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN"
  security import "$tmp/id.p12" -k "$SIGN_KEYCHAIN" -P "$SIGN_PASS" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$SIGN_PASS" "$SIGN_KEYCHAIN" >/dev/null
  rm -rf "$tmp"
}

sign_with_local_identity() {
  [ -f "$SIGN_KEYCHAIN" ] || create_signing_identity
  security unlock-keychain -p "$SIGN_PASS" "$SIGN_KEYCHAIN"

  # codesign 只在钥匙串搜索列表里找证书：临时加进去，签完立刻恢复
  local original=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [ -n "$line" ] && original+=("$line")
  done < <(security list-keychains -d user)
  trap 'security list-keychains -d user -s "${original[@]}"' RETURN
  security list-keychains -d user -s "${original[@]}" "$SIGN_KEYCHAIN"
  codesign --force --deep --sign "$SIGN_NAME" "$APP"
}

if sign_with_local_identity 2>/dev/null; then
  echo "==> 已用本地证书签名（重新编译后辅助功能权限不会失效）"
else
  echo "==> 本地证书签名失败，改用临时签名（重新编译后需要重新授权辅助功能）"
  codesign --force --deep --sign - "$APP"
fi
echo "==> 完成：$APP"

if [ "${1:-}" = "install" ]; then
  echo "==> 安装到 /Applications"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/"
  open "/Applications/$APP_NAME.app"
  echo "==> 已启动 /Applications/$APP_NAME.app"
fi
