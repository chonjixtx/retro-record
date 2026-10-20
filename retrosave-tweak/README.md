# RetroSaveInGame —— 游戏内「回溯」保存悬浮按钮

## ⚠️ 先读这段

- **只建议自用，不要分发。** 分发给他人会把法律风险从"几乎为零"拉到"实打实"。
- **封号风险是确定的，不是"可能"。** 手游用户协议普遍禁止注入第三方代码；反作弊
  检测看的是「进程里有没有非系统动态库」，**不会因为你只是加了个按钮就放过**。
  越狱状态本身也会被风控标记。账号被封与本项目无关，请自行权衡。
- 本 tweak **不 hook 任何游戏方法、不读写游戏内存、不修改游戏数据**，
  只往游戏当前的 keyWindow 上加一颗按钮，点一下通过 Darwin 通知告诉「回溯」去保存。

## 工作原理

游戏内按钮 → Darwin 通知 `com.retro.recorder.trigger.<秒数>` → 回溯的录制扩展
（录制期间必定存活）→ 收尾分片 → 导出 → 存相册。**游戏不会被切走。**

两个关键设计点：

1. **不用 URL scheme**：打开 `retrorecord://save` 会把游戏切到后台。Darwin 通知不会。
2. **指令不能发给主 App**：打游戏时主 App 已被系统挂起，Darwin 通知唤不醒挂起进程。
   所以指令发给录制扩展。

需要回溯 **build22 或更高**（内置 trigger 通道），旧版本收不到指令。

## 注入目标

`RetroSaveInGame.plist` 里的 Bundle ID 已通过 App Store 官方接口确认为
**`com.juzi.balls`**（球球大作战 / Battle of Balls，巨人网络）。

如果要换成别的游戏，改这一行即可：

```
{ Filter = { Bundles = ( "com.juzi.balls" ); }; }
```

查询任意 App 的 Bundle ID（不需要越狱）：

```
https://itunes.apple.com/lookup?id=<App Store 数字 ID>&country=cn     →  看 bundleId 字段
```

## 前置条件

1. 设备已越狱（rootless：dopamine / palera1n；roothide：Dopamine roothide 等）
2. 已装回溯 build22+，能正常录屏
3. 已装 Substitute/ElleKit 注入框架（越狱自带）

## 产物说明

| 文件 | 用在哪 |
|---|---|
| `RetroSaveInGame-rootless.deb` | dopamine / palera1n rootless —— data.tar 里路径带 `var/jb/` 前缀 |
| `RetroSaveInGame-roothide.deb` | roothide —— 路径不带前缀，dpkg 会自动重定位到随机 jbroot |
| `RetroSaveInGame.dylib` | 兜底用：手动塞进注入目录（见下） |

dylib 为 **arm64 + arm64e 双架构 fat**，已做 ad-hoc 签名。

## 安装

### 方式一：装 deb（推荐）

把对应 deb 传到设备（Filza / scp / 隔空投送都行），然后：

```bash
# 命令行
dpkg -i RetroSaveInGame-rootless.deb     # 或 -roothide.deb

# 或者 Filza 里直接点开 deb → 安装

# 让 tweak 生效
killall backboardd      # 或 sbreload
```

确认文件真的落到了正确目录：

```bash
# rootless
ls /var/jb/Library/MobileSubstrate/DynamicLibraries/ | grep Retro
# roothide（jbroot 路径随机，用 Sileo/Filza 的越狱根目录进去看）
ls Library/MobileSubstrate/DynamicLibraries/ | grep Retro
```

应该看到 `RetroSaveInGame.dylib` 和 `RetroSaveInGame.plist` 两个文件。

### 方式二：手动放 dylib（deb 装不上的兜底）

1. 用 Filza 把 `RetroSaveInGame.dylib` 和 `RetroSaveInGame.plist` 拷进
   上面的 DynamicLibraries 目录
2. 权限设成 `0755`（dylib）和 `0644`（plist）
3. `killall backboardd`

## 使用

1. 打开**回溯** → 点「开始录制」→ 系统弹层确认，状态栏出现录制指示
2. 切进游戏，等约 2.5 秒，屏幕左侧中间会出现一颗黑色圆按钮「回溯 60s」
3. 打完精彩的一段，**点一下按钮** → 底部弹提示「已请求保存最近 60 秒」→ 相册里就有视频了
4. **长按 0.8 秒**：在 30 / 60 / 120 秒之间切档
5. **拖动**：挪按钮位置（位置和档位会记住）

游戏全程不会被切走，也不会因为保存而卡顿。

## 按钮没出现？按顺序排查

```bash
# 1) dylib 在不在注入目录
ls /var/jb/Library/MobileSubstrate/DynamicLibraries/ | grep Retro

# 2) Bundle ID 对不对（必须和游戏进程一致）
plutil -p /var/jb/Library/MobileSubstrate/DynamicLibraries/RetroSaveInGame.plist

# 3) 看注入有没有报错（另开一个终端再进游戏）
log stream | grep -i RetroSave
```

最常见的原因：

- **Bundle ID 填错** —— 用上面的 itunes lookup 确认
- **rootless / roothide 选错了 deb** —— 装到了读不进的路径，表现为"装成功但没效果"
- **没签名** —— 越狱设备上注入的 dylib 需要至少 ad-hoc 签名，NewTerm 里补一下：
  ```bash
  cd /var/jb/Library/MobileSubstrate/DynamicLibraries/
  ldid -S RetroSaveInGame.dylib
  killall backboardd
  ```
- **游戏有反作弊/越狱检测** —— 可能直接闪退或主动屏蔽注入

## 自己编译

### 有 Mac（Xcode 命令行工具即可，不需要 Theos）

```bash
cd retrosave-tweak
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
$CC -isysroot $SDK -miphoneos-version-min=15.0 -fobjc-arc -Os -dynamiclib \
    -install_name /Library/MobileSubstrate/DynamicLibraries/RetroSaveInGame.dylib \
    -framework UIKit -framework QuartzCore -framework CoreGraphics \
    -arch arm64 -o RetroSaveInGame.dylib RetroSaveInGame.m
ldid -S RetroSaveInGame.dylib
python3 ../tools/make_deb.py RetroSaveInGame.dylib RetroSaveInGame.plist \
        control-rootless control-roothide out/
```

### 用仓库自带的 CI 脚本

`tools/build_tweak.sh` 会在每次 IPA 构建时顺带跑一遍，把 deb 以 base64 打进构建日志。
脚本全程 `set +e` 且结尾 `exit 0`，失败也不影响 IPA 产出。

### 用 Theos（老办法）

`Makefile` 保留着，`make package FINALPACKAGE=1` 可以照常跑（依赖 Theos + Logos，
编的是 `Tweak.xm`）。

## 交互一览

| 操作 | 效果 |
|---|---|
| 单击 | 保存最近 N 秒（默认 60） |
| 长按 0.8 秒 | 在 30 / 60 / 120 秒之间切档 |
| 拖动 | 挪按钮位置 |
