#!/bin/bash
# 在 xcodebuild 的 postBuildScript 阶段执行：顺带把 retrosave-tweak 编成 dylib 并打成 deb。
# 任何失败都不能挡住主 App 的 archive —— 全程 set +e，最后 exit 0。
# 产物以 base64 打进构建日志（===B64_XXX_START=== / ===B64_XXX_END=== 之间）。
set +e
echo "==== TWEAK_BUILD_START ===="

cd "$SRCROOT/retrosave-tweak" || { echo "no retrosave-tweak dir"; exit 0; }

SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
CC=$(xcrun --sdk iphoneos -f clang 2>/dev/null)
echo "SDK=$SDK"
echo "CC=$CC"
if [ -z "$SDK" ] || [ -z "$CC" ]; then echo "no iphoneos sdk"; exit 0; fi

rm -rf .tb && mkdir -p .tb

COMMON="-isysroot $SDK -miphoneos-version-min=15.0 -fobjc-arc -Os -dynamiclib \
        -install_name /Library/MobileSubstrate/DynamicLibraries/RetroSaveInGame.dylib \
        -framework UIKit -framework QuartzCore"

echo "--- build arm64 ---"
$CC $COMMON -arch arm64 -o .tb/arm64.dylib RetroSaveInGame.m 2>&1 | tail -25
echo "arm64 rc=$? size=$(wc -c < .tb/arm64.dylib 2>/dev/null)"

echo "--- build arm64e ---"
$CC $COMMON -arch arm64e -o .tb/arm64e.dylib RetroSaveInGame.m 2>&1 | tail -25
echo "arm64e size=$(wc -c < .tb/arm64e.dylib 2>/dev/null)"

if [ -s .tb/arm64.dylib ] && [ -s .tb/arm64e.dylib ]; then
  lipo -create -output .tb/RetroSaveInGame.dylib .tb/arm64.dylib .tb/arm64e.dylib 2>&1 | tail -5
  echo "fat ok"
elif [ -s .tb/arm64.dylib ]; then
  cp .tb/arm64.dylib .tb/RetroSaveInGame.dylib
  echo "arm64 only"
elif [ -s .tb/arm64e.dylib ]; then
  cp .tb/arm64e.dylib .tb/RetroSaveInGame.dylib
  echo "arm64e only"
fi

DYLIB=.tb/RetroSaveInGame.dylib
if [ ! -s "$DYLIB" ]; then echo "DYLIB MISSING"; exit 0; fi
lipo -info "$DYLIB"

# ---- 签名：越狱设备上注入的 dylib 需要至少 ad-hoc 签名 ----
brew install ldid >/dev/null 2>&1
LDID_BIN=$(command -v ldid)
if [ -n "$LDID_BIN" ]; then
  "$LDID_BIN" -S "$DYLIB" >/dev/null 2>&1
  echo "signed: ldid rc=$?"
else
  codesign -s - --force "$DYLIB" >/dev/null 2>&1
  echo "signed: codesign ad-hoc rc=$?"
fi

python3 "$SRCROOT/tools/make_deb.py" \
  "$DYLIB" \
  "$SRCROOT/retrosave-tweak/RetroSaveInGame.plist" \
  "$SRCROOT/retrosave-tweak/control-rootless" \
  "$SRCROOT/retrosave-tweak/control-roothide" \
  "$SRCROOT/.tb-out"

echo "==== TWEAK_BUILD_END ===="
exit 0
