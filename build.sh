#!/usr/bin/env bash
# 编译 Yaya 并组装成可运行的 .app
#
# 用法：
#   ./build.sh              # 编译 + 组装 + ad-hoc 签名
#   ./build.sh --no-sign    # 只组装不签名（想自己用其他证书签时）
#
# 需要：macOS 15+、Xcode Command Line Tools（xcode-select --install）

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Yaya"
BUNDLE_ID="cn.lingxiu.yaya"
APP="${APP_NAME}.app"
SIGN=1
[[ "${1:-}" == "--no-sign" ]] && SIGN=0

# 某些受限环境下 SwiftPM 自带的沙箱会失败，可用 SWIFT_FLAGS 传参绕过
SWIFT_FLAGS="${SWIFT_FLAGS:-}"

echo "==> 1/4 编译"
swift build -c release ${SWIFT_FLAGS}

echo "==> 2/4 生成图标"
if [[ -d icon.iconset ]]; then
  iconutil -c icns icon.iconset -o /tmp/AppIcon.icns
  ICON_OK=1
else
  echo "    （没有 icon.iconset，跳过）"
  ICON_OK=0
fi

echo "==> 3/4 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources/assets"

cp ".build/release/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp packaging/Info.plist "${APP}/Contents/Info.plist"
[[ ${ICON_OK} == 1 ]] && cp /tmp/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

# 菜单栏图标（有就带上）
for f in menubar.png menubar@2x.png; do
  [[ -f "${f}" ]] && cp "${f}" "${APP}/Contents/Resources/"
done

# 宠物贴图等运行时资源
if compgen -G "assets/*.png" > /dev/null; then
  cp assets/*.png "${APP}/Contents/Resources/assets/"
fi

echo "==> 4/4 签名"
if [[ ${SIGN} == 1 ]]; then
  # ad-hoc 签名：不需要开发者账号，任何人 clone 后都能跑
  # 想用自有证书：codesign --force --deep --sign "证书名" "${APP}"
  codesign --force --deep --sign - "${APP}"
  codesign --verify --verbose=1 "${APP}"
else
  echo "    （已跳过签名）"
fi

echo
echo "✅ 完成：$(pwd)/${APP}"
echo "   首次运行需要手动授予「屏幕录制」权限："
echo "   系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 ${APP_NAME}"
echo "   然后把 ${APP} 拖进「应用程序」文件夹，再执行："
echo "   open -a \"$(pwd)/${APP}\""
