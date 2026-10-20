# RetroSaveInGame —— 游戏内悬浮窗（v2）

在球球大作战进程里画一个悬浮球 + 控制面板，用来**开启录屏、保存回放、调时长、调码率**。

不 hook 任何游戏方法、不读写游戏内存、不修改游戏任何逻辑与数据。

> ### 风险提示（必读）
> - 注入必然违反球球大作战的用户协议。反作弊扫的是「进程里有没有非系统动态库」，
>   **不会因为只画了个界面就放过**；越狱状态本身也会被风控标记。
> - 只建议自用，不要分发。

---

## 一、它能做什么 / 不能做什么

| 功能 | 在哪完成 |
|---|---|
| 开启录屏（弹系统「开始直播」，你手动确认） | ✅ 游戏内悬浮窗 |
| 保存最近 30 / 60 / 120 秒 | ✅ 游戏内悬浮窗 |
| 调时长档位 | ✅ 游戏内悬浮窗 |
| 调码率 4 / 6 / 8 / 12 Mbps | ✅ 游戏内悬浮窗（下一段分片生效） |
| 真正的采帧 / 分片 / 拼接 / 写相册 | ❌ 必须由「回溯」App 的 Broadcast Upload Extension 提供 |

**录屏内核挪不进 dylib** —— iOS 的 ReplayKit 录屏能力由 Broadcast Upload Extension 提供，
它必须寄生在一个 App 包体里，由系统注册。这是 iOS 的组织方式，越狱也改不了。

所以存在两种装法，二选一：

- **All-in-One deb（推荐）**：一个 deb 同时装上「App 本体 + 插件」，装一次搞定，
  不用再单独传 ipa，也不用巨魔。见 `使用说明-AllinOne.md`。
- **分开装**：ipa 用巨魔装（App 本体）+ deb 装插件。功能体验完全一样，只是多一步。

---

## 二、安装（只装插件时）

1. 把 `RetroSaveInGame-rootless.deb`（dopamine / palera1n）或
   `RetroSaveInGame-roothide.deb`（roothide）传到设备
2. Sileo / Filza 打开安装
3. `killall backboardd`（或 `sbreload`）

手动装法（deb 装不上时）：把 `RetroSaveInGame.dylib` 和 `RetroSaveInGame.plist` 一起放进
`/var/jb/Library/MobileSubstrate/DynamicLibraries/`，权限 0755 / 0644，然后 respring。

---

## 三、使用

进游戏等约 2.5 秒，屏幕左侧中间出现黑色圆球「回溯 60s」。

- **点一下圆球** → 展开控制面板；再点收起
- **长按圆球 0.8 秒** → 直接保存（不用展开面板）
- **拖动圆球** → 挪位置（位置、时长、码率都记在游戏自己的 NSUserDefaults 里）

面板四块：

1. **① 开启录屏** —— 点左边那个系统控件，直接弹出 iOS 的「开始直播」面板，
   选「回溯录制」→ 开始直播。**弹窗是从游戏进程发起的，所以盖在游戏上面，不用切出去。**
   用的是系统公开 API `RPSystemBroadcastPickerView`，已预设只推「回溯录制」。
2. **② 保存最近 N 秒** —— 点一下保存。1.8 秒内没等到录制进程回执，
   会自动拉起「回溯」App 兜底保存，**绝不出现「点了但相册没有」**。
3. **③ 时长** —— 30 / 60 / 120 秒
4. **④ 码率** —— 4 / 6 / 8 / 12 Mbps，改完立刻切一段新分片，几秒内生效

---

## 四、排查

| 现象 | 检查 |
|---|---|
| 圆球不出现 | `ls /var/jb/Library/MobileSubstrate/DynamicLibraries/ \| grep Retro` 看文件在不在 |
| 文件在但不出球 | 核对 plist 里的 Bundle ID 是不是 `com.juzi.balls`（球球大作战真实 ID） |
| 出球但点了没视频 | 先确认录制已开启（状态栏有红色/蓝色录制标记） |
| 弹不出「开始直播」 | App 本体没装或没刷新：`uicache -a` 后 respring |
| 注入报错 | `log stream \| grep -i RetroSave` |

---

## 五、构建

纯 Objective-C 动态库，不依赖 Theos / Logos：

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
$CC -isysroot $SDK -miphoneos-version-min=15.0 -fobjc-arc -w -Os -dynamiclib \
    -install_name /Library/MobileSubstrate/DynamicLibraries/RetroSaveInGame.dylib \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework ReplayKit \
    -arch arm64  -o arm64.dylib  RetroSaveInGame.m
# arm64e 同理，然后 lipo 合并
ldid -S RetroSaveInGame.dylib
```

`ReplayKit` 是「开启录屏」的关键，漏了会报
`_OBJC_CLASS_$_RPSystemBroadcastPickerView` 未定义。

Filter：`RetroSaveInGame.plist` 里 `Bundles = ( "com.juzi.balls" )`。
