#!/bin/bash
# 装到 iPhone Duo：一条命令，用「Duo 证书」那套签名。
#
#   Scripts/install-duo.sh                    # 构建 + 装 + 启动
#   Scripts/install-duo.sh --build-only       # 只出包
#   Scripts/install-duo.sh --device <UDID>    # 换设备（默认取连接中的第一台真机）
#
# 证书目录固定为 ~/Documents/windows11/编程工具/mac/证书/Duo 证书/：
#   ios_development.p12（密码 1）+ all1023.mobileprovision
# 首次运行会把 p12 导入登录钥匙串、把描述文件装进 ~/Library/MobileDevice/Provisioning Profiles。
# 之后 project.yml 里的 team/profile 设置会直接生效，脚本只负责挑设备和收尾。
set -euo pipefail

CERT_DIR="$HOME/Documents/windows11/编程工具/mac/证书/Duo 证书"
P12="$CERT_DIR/ios_development.p12"
PROFILE="$CERT_DIR/all1023.mobileprovision"
P12_PASSWORD="${P12_PASSWORD:-1}"
BUNDLE_ID="wda.prdc.yingxia.dev"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE=""
BUILD_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only) BUILD_ONLY=1; shift ;;
        --device) DEVICE="$2"; shift 2 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

step "证书"
if [[ ! -f "$P12" || ! -f "$PROFILE" ]]; then
    echo "找不到证书：$CERT_DIR" >&2; exit 1
fi
# 身份已存在就不再导入，免得钥匙串里堆一串同名副本。
if ! security find-identity -v -p codesigning | grep -q "Q4LPR7GXL8"; then
    security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P12_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    echo "已导入 p12"
fi
PROFILE_PLIST=$(mktemp)
security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print :UUID" "$PROFILE_PLIST")
PROFILE_DEST="$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
mkdir -p "$(dirname "$PROFILE_DEST")"
[[ -f "$PROFILE_DEST" ]] || cp "$PROFILE" "$PROFILE_DEST"
echo "profile $PROFILE_UUID 就位"
# 描述文件里的设备白名单：装机失败十有八九是这一步对不上。
PROFILE_DEVICES=$(/usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$PROFILE_PLIST" 2>/dev/null | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | tr '\n' ' ')
echo "该 profile 授权设备：${PROFILE_DEVICES:-（企业签名，无限制）}"

step "生成工程"
cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null && echo "xcodegen 已刷新"

step "构建"
xcodebuild -project TVBox.xcodeproj -scheme TVBox-iOS -destination 'generic/platform=iOS' \
    -configuration Debug -quiet build
APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/TVBox-*/Build/Products/Debug-iphoneos/*.app | head -1)
echo "$APP"
codesign -dv --entitlements :- "$APP" 2>&1 | grep -E "TeamIdentifier|Identifier=" || true
[[ $BUILD_ONLY -eq 1 ]] && exit 0

step "挑设备"
if [[ -z "$DEVICE" ]]; then
    DEVICE=$(xcrun devicectl list devices 2>/dev/null \
        | awk '/available \(paired\)/ && /physical/ {print $0}' | head -1 \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}')
fi
if [[ -z "$DEVICE" ]]; then
    echo "没有可用的真机。解锁手机、开开发者模式、连上数据线后再跑。" >&2
    echo "（构建已完成，包在上面那个路径。）" >&2
    exit 3
fi
echo "设备 $DEVICE"
if [[ -n "$PROFILE_DEVICES" && "$PROFILE_DEVICES" != *"$DEVICE"* ]]; then
    echo "⚠️  这台设备的 UDID 不在描述文件里，安装会失败。" >&2
    echo "    要么插上 ${PROFILE_DEVICES% } 那台，要么把 $DEVICE 加进 Apple Developer 后台重新生成 profile。" >&2
    exit 4
fi

step "安装"
xcrun devicectl device install app --device "$DEVICE" "$APP"

step "启动"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || true
