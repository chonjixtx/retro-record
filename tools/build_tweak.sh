#!/bin/bash
# 在 xcodebuild 的 postBuildScript 阶段执行：顺带把 retrosave-tweak 编成 dylib 并打成 deb。
#
# 两条铁律：
#  1) 任何失败都不能挡住主 App 的 archive —— 全程 set +e，最后 exit 0。
#  2) 绝不能往 stdout/stderr 吐 "error:" —— Xcode 只要看到这个词，即使脚本 exit 0
#     也会把整个 PhaseScriptExecution 判成失败（** ARCHIVE FAILED **，exit 65）。
#     所以所有子命令输出都先落 .tb/build.log，打印前统一把 error: 改写成 err:。
#
# 产物以 base64 打进构建日志（===B64_XXX_START=== / ===B64_XXX_END=== 之间）。
set +e
echo "==== TWEAK_BUILD_START ===="

cd "$SRCROOT/retrosave-tweak" || { echo "no retrosave-tweak dir"; exit 0; }

SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
CC=$(xcrun --sdk iphoneos -f clang 2>/dev/null)
echo "SDK=$SDK"
if [ -z "$SDK" ] || [ -z "$CC" ]; then echo "no iphoneos sdk"; exit 0; fi

rm -rf .tb && mkdir -p .tb
LOG=.tb/build.log
: > "$LOG"

# ReplayKit 是「开启录屏」按钮的关键：RPSystemBroadcastPickerView 属于这个框架，
# 少了它链接会报 _OBJC_CLASS_$_RPSystemBroadcastPickerView 未定义。
COMMON="-isysroot $SDK -miphoneos-version-min=15.0 -fobjc-arc -w -Os -dynamiclib \
        -install_name /Library/MobileSubstrate/DynamicLibraries/RetroSaveInGame.dylib \
        -framework UIKit -framework QuartzCore -framework CoreGraphics -framework ReplayKit"

$CC $COMMON -arch arm64  -o .tb/arm64.dylib  RetroSaveInGame.m  >>"$LOG" 2>&1
R64=$?
$CC $COMMON -arch arm64e -o .tb/arm64e.dylib RetroSaveInGame.m  >>"$LOG" 2>&1
R64E=$?
echo "clang rc: arm64=$R64 arm64e=$R64E"
echo "sizes: arm64=$( [ -s .tb/arm64.dylib ] && wc -c < .tb/arm64.dylib ) arm64e=$( [ -s .tb/arm64e.dylib ] && wc -c < .tb/arm64e.dylib )"

if [ -s .tb/arm64.dylib ] && [ -s .tb/arm64e.dylib ]; then
  lipo -create -output .tb/RetroSaveInGame.dylib .tb/arm64.dylib .tb/arm64e.dylib >>"$LOG" 2>&1
  echo "link: fat (arm64+arm64e)"
elif [ -s .tb/arm64.dylib ]; then
  cp .tb/arm64.dylib .tb/RetroSaveInGame.dylib
  echo "link: arm64 only"
elif [ -s .tb/arm64e.dylib ]; then
  cp .tb/arm64e.dylib .tb/RetroSaveInGame.dylib
  echo "link: arm64e only"
fi

# 打印编译日志（已脱敏，不会触发 Xcode 的失败判定）
echo "---- build.log (tail) ----"
sed -e 's/error:/err:/g' -e 's/Error:/Err:/g' -e 's/ERROR:/ERR:/g' "$LOG" | tail -40
echo "---- build.log end ----"

DYLIB=.tb/RetroSaveInGame.dylib
if [ ! -s "$DYLIB" ]; then
  echo "DYLIB MISSING"
  echo "==== TWEAK_BUILD_END ===="
  exit 0
fi
lipo -info "$DYLIB" 2>&1 | sed -e 's/error:/err:/g'
echo "dylib bytes=$(wc -c < "$DYLIB")"

# ---- 签名：越狱设备上注入的 dylib 至少需要 ad-hoc 签名 ----
brew install ldid >>"$LOG" 2>&1
LDID_BIN=$(command -v ldid)
if [ -n "$LDID_BIN" ]; then
  "$LDID_BIN" -S "$DYLIB" >>"$LOG" 2>&1
  echo "signed with ldid rc=$?"
else
  codesign -s - --force "$DYLIB" >>"$LOG" 2>&1
  echo "signed with codesign ad-hoc rc=$?"
fi
echo "after sign bytes=$(wc -c < "$DYLIB")"

python3 "$SRCROOT/tools/make_deb.py" \
  "$DYLIB" \
  "$SRCROOT/retrosave-tweak/RetroSaveInGame.plist" \
  "$SRCROOT/retrosave-tweak/control-rootless" \
  "$SRCROOT/retrosave-tweak/control-roothide" \
  "$SRCROOT/.tb-out"

echo "==== TWEAK_BUILD_END ===="
exit 0
