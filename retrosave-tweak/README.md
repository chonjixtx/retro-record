# RetroSaveInGame —— 游戏内回溯保存悬浮按钮

## ⚠️ 先读这段

- **只建议自用，不要分发。** 分发给他人会把法律风险从"几乎为零"拉到"实打实"。
- **封号风险是确定的，不是"可能"。** 手游用户协议普遍禁止注入第三方代码；反作弊
  检测看的是「进程里有没有非系统动态库」，**不会因为你只是加了个按钮就放过**。
  越狱状态本身也会被风控标记。账号被封与本项目无关，请自行权衡。
- 本 tweak **不 hook 任何游戏方法、不读写游戏内存、不修改游戏数据**，
  只往游戏当前的 keyWindow 上加一颗按钮。

## 工作原理

游戏内按钮 → Darwin 通知 `com.retro.recorder.trigger.<秒数>` → 回溯的录制扩展
（录制期间必定存活）→ 收尾分片 → 导出 → 存相册。**游戏不会被切走。**

两个关键设计点：

1. **不用 URL scheme**：打开 `retrorecord://save` 会把游戏切到后台。Darwin 通知不会。
2. **指令不能发给主 App**：打游戏时主 App 已被系统挂起，Darwin 通知唤不醒挂起进程。
   所以指令发给录制扩展。

需要回溯 **build22 或更高**（内置 trigger 通道），旧版本收不到指令。

## 前置条件

1. iPad 已越狱（iPad Pro 11" 2代 / iOS 15.4.1 用 **dopamine**，它支持 15.0–16.5.1 且支持 A12 的 arm64e）
2. 已装回溯 build22，并能正常录屏
3. 一台能跑 Theos 的机器：macOS 或 Linux 或 Windows 的 WSL（**Windows 原生不行**）

## 第一步：确认游戏 Bundle ID

`RetroSaveInGame.plist` 里现在是 `com.giant.battleofballs`（**猜测值，必须核对**）。

SSH 进设备查真实 ID：

```bash
ps -A | grep -i ball
# 或者列出所有 App 的 bundle 目录
ls /var/containers/Bundle/Application/*/*.app/
```

改对后保存。

## 第二步：构建

### 方案 A（推荐）：用 GitHub Actions 免费编，不用自己准备 Mac

1. 打开仓库 → `Add file` → `Create new file`
2. 文件名填：`.github/workflows/build-tweak.yml`
3. 内容粘贴同目录下的 `github-action-build-deb.yml`
4. `Commit changes` —— Actions 会自动开始跑
5. 跑完后进 `Actions` → 最新的 `build-tweak` → 底部 `RetroSaveInGame-deb` 下载

### 方案 B：本地有 Mac / Linux / WSL

```bash
# 1) 装 Theos
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos

# 2) iOS SDK（Theos 若没自带，需要一个 iPhoneOS SDK 放进 $THEOS/sdks/）
#    macOS 上可从 Xcode 里取：
#    /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
#    打包成 iPhoneOS15.4.sdk.tar 放进去即可

# 3) 编译打包
cd retrosave-tweak
make package
```

产物：`packages/com.retro.saveingame_1.0-1_iphoneos-arm.deb`

> 若 dpkg 报找不到 `mobilesubstrate`，把 `control` 里那行 Depends 删掉再编
> （rootless 越狱里 Substrate 常由 ElleKit 提供，包名不一定叫这个）。

## 第三步：安装

把 deb 传到设备（Filza / scp 都行），然后：

```bash
# rootless（dopamine）下用这一套
dpkg -i com.retro.saveingame_1.0-1_iphoneos-arm.deb
# 或者用 Filza 直接点开 deb 安装

# 让 tweak 生效
killall backboardd     # 或 sbreload
```

确认 dylib 真的落到了 rootless 路径：

```bash
ls /var/jb/Library/MobileSubstrate/DynamicLibraries/
# 应该看到 RetroSaveInGame.dylib 和 RetroSaveInGame.plist
```

## 第四步：使用

1. 打开**回溯** → 点「开始录制」→ 系统弹层确认，状态栏出现录制指示
2. 切进游戏，等约 2.5 秒，屏幕左侧中间会出现一颗黑色圆按钮「回溯 60s」
3. 打完精彩的一段，**点一下按钮** → 底部弹提示「已保存最近 60 秒」→ 相册里就有视频了
4. **长按 0.8 秒**：在 30 / 60 / 120 秒之间切档
5. **拖动**：挪按钮位置（位置和档位会记住）

游戏全程不会被切走，也不会因为保存而卡顿。

## 按钮没出现？按顺序排查

```bash
# 1. dylib 在不在 rootless 路径
ls /var/jb/Library/MobileSubstrate/DynamicLibraries/ | grep Retro

# 2. Bundle ID 对不对（必须和游戏进程一致）
plutil -p /var/jb/Library/MobileSubstrate/DynamicLibraries/RetroSaveInGame.plist

# 3. 看注入有没有报错（另开一个终端再进游戏）
log stream | grep -i RetroSave
```

最常见的原因是 **Bundle ID 填错** 和 **忘了 rootless**（装到了 `/Library/MobileSubstrate`，
rootless 下系统不读那个路径，表现为"装成功但没效果"）。

## 交互一览

| 操作 | 效果 |
|---|---|
| 单击 | 保存最近 N 秒（默认 60） |
| 长按 0.8 秒 | 在 30 / 60 / 120 秒之间切档 |
| 拖动 | 挪按钮位置 |
