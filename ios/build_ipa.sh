#!/usr/bin/env bash
# ============================================================
#  build_ipa.sh —— 一键把 LeapmotorLite 打成 .ipa
#
#  必须在 macOS 上跑（iOS 应用只能用 Xcode 工具链编译）。
#
#  未签名（默认，给 Sideloadly / AltStore / TrollStore 用）：
#      bash ios/build_ipa.sh
#
#  用你自己的开发者证书签名（需要已装好证书+描述文件）：
#      DEVELOPMENT_TEAM=ABCDE12345 bash ios/build_ipa.sh
#      DEVELOPMENT_TEAM=ABCDE12345 \
#        SIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)" \
#        PROVISIONING_PROFILE_SPECIFIER="LeapmotorLite Dev" \
#        bash ios/build_ipa.sh
#
#  产物：dist/LeapmotorLite-unsigned.ipa  或  dist/LeapmotorLite-signed.ipa
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ_DIR="$ROOT/ios/LeapmotorLite"
SCHEME="LeapmotorLite"
APP_NAME="LeapmotorLite"
BUILD_DIR="$PROJ_DIR/build"
OUT_DIR="$ROOT/dist"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0) 平台检查 ----------
[[ "$(uname -s)" == "Darwin" ]] || die "必须在 macOS 上运行（需要 Xcode 的 iOS 工具链）。
    没有 Mac 就用 GitHub Actions：见 IPA_BUILD.md 的「方案 A」。"
command -v xcodebuild >/dev/null 2>&1 || die "找不到 xcodebuild。请先装 Xcode 并执行：
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
command -v python3 >/dev/null 2>&1 || die "找不到 python3（macOS 自带，或 brew install python）"

say "Xcode: $(xcodebuild -version | head -1)"

# ---------- 1) 图标 ----------
ICON="$PROJ_DIR/$APP_NAME/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
if [[ ! -f "$ICON" ]]; then
  say "生成 App 图标…"
  python3 "$ROOT/ios/tools/make_icon.py" || warn "图标生成失败，跳过（不影响构建）"
fi

# ---------- 2) 生成 .xcodeproj ----------
say "生成 Xcode 工程…"
python3 "$ROOT/ios/tools/gen_xcodeproj.py"

# ---------- 3) 组装构建参数 ----------
SIGN_ARGS=(
  CODE_SIGN_IDENTITY=""
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_ENTITLEMENTS=""
)
SUFFIX="unsigned"

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  say "签名模式：DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
  SIGN_ARGS=(
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
  )
  [[ -n "${PROVISIONING_PROFILE_SPECIFIER:-}" ]] && \
    SIGN_ARGS+=(PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE_SPECIFIER")
  SUFFIX="signed"
else
  warn "未签名模式（给 Sideloadly / AltStore / TrollStore 再签名用）"
fi

# ---------- 4) 构建 ----------
say "xcodebuild (Release / iphoneos)…"
rm -rf "$BUILD_DIR"
set -x
xcodebuild \
  -project "$PROJ_DIR/$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$BUILD_DIR" \
  "${SIGN_ARGS[@]}" \
  build
set +x

APP="$BUILD_DIR/Build/Products/Release-iphoneos/$APP_NAME.app"
[[ -d "$APP" ]] || die "构建产物不存在：$APP"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null || echo '?')"
say "产物: $APP"
say "BundleID: $BUNDLE_ID"

# ---------- 5) 打包成 .ipa ----------
say "打包 .ipa…"
rm -rf "$OUT_DIR/Payload"
mkdir -p "$OUT_DIR/Payload"
cp -R "$APP" "$OUT_DIR/Payload/"
IPA="$OUT_DIR/$APP_NAME-$SUFFIX.ipa"
rm -f "$IPA"
( cd "$OUT_DIR" && zip -qry "$(basename "$IPA")" Payload )
rm -rf "$OUT_DIR/Payload"

say "完成 → $IPA"
ls -lh "$IPA"

cat <<EOF

────────── 安装方式 ──────────
未签名 IPA 需要用工具用你自己的 Apple ID 重签后安装：

  • Sideloadly（Windows / macOS，最省事）
      1. 装 iTunes（Windows 版）或确保有 Apple 驱动
      2. 打开 Sideloadly，连上 iPhone
      3. 把 $IPA 拖进去，填 Apple ID
      4. Start → 手机 设置→通用→VPN与设备管理 里信任开发者
      ⚠️ 免费 Apple ID 签的有效期 7 天，到期重签

  • AltStore / SideStore（手机上自签，需常驻）
  • TrollStore（仅特定 iOS 版本，装了可永久免签）

────────── 首次使用 ──────────
  1. 打开 App → 设置 → 诊断 → 算法自检，应全部通过
  2. 首页输手机号 → 获取验证码 → 填码登录
  3. 设置 → 操作密码，填 6 位车控密码
  4. 车控页点按钮

EOF
