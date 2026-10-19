# 回溯 · iOS 循环录屏（.ipa / 全能签）

打开即持续录制、只保留最近 N 秒（默认 600 秒）、点一下把最近 N 秒存成 mp4。
已按 iOS 真实能力边界落地：**Broadcast Upload Extension 全屏录制 + 10 秒分段环形缓冲 + 1080P 导出 + 灵劫岛常驻胶囊 + App 内悬浮球**。

---

## 一、先看这三条，避免白折腾

| 你以为的 | 实际在 iOS 上 |
|---|---|
| 打开 App 就自动开始后台录像 | ❌ 必须由你本人在系统弹层点一次「开始录制」。iOS 13 起强制要求真实触控，任何签名方式（含全能签）都绕不过 |
| 后台有个圆形「回溯」悬浮窗盖在别的 App 上 | ❌ iOS 不允许 App 越界绘制。替代：灵劫岛/锁屏常驻胶囊（一直可见、点一下唤起 App）+ App 内悬浮球 |
| 全能签可以突破沙盒 | ❌ 全能签只是重签名工具，解决「装得上」，不解决「能干什么」 |

另外两条必须接受：
- 录制期间状态栏常驻系统录制指示器，**无法隐藏**；
- 锁屏 / 息屏 / 来电会中断录制（这是系统行为，不是 bug）。

---

## 二、工程结构

```
回溯录屏-iOS/
├── project.yml                     XcodeGen 工程定义（三个 target）
├── Sources/
│   ├── Shared/                     主 App 与扩展共用
│   │   ├── AppIdentifiers.swift    Bundle ID / App Group 常量
│   │   ├── AppGroup.swift          共享容器
│   │   ├── RecorderConfig.swift    保留时长 / 码率 / 麦克风
│   │   ├── SegmentStore.swift      分段环形缓冲（落盘 + 修剪）
│   │   ├── Heartbeat.swift         心跳，用于判断"还在不在录"
│   │   └── RetroActivityAttributes.swift  灵动岛数据模型（扩展不编译）
│   ├── RecorderExtension/
│   │   └── SampleHandler.swift     录制内核：AVAssetWriter 分段落盘
│   ├── App/
│   │   ├── RetroRecordApp.swift
│   │   ├── ContentView.swift       主界面
│   │   ├── RecorderViewModel.swift 状态轮询 / 保存 / 相册
│   │   ├── SegmentMerger.swift     片段拼接 + 1080P 导出
│   │   ├── BroadcastStarter.swift  系统录屏选择器（换成自己的外观）
│   │   ├── FloatingBall.swift      圆形"回溯"悬浮球
│   │   └── LiveActivityManager.swift
│   └── Widget/                     灵动岛 / 锁屏胶囊
├── Resources/                      Info.plist / entitlements / AppIcon
├── tools/make_app_icon.py          重新生成图标（纯标准库）
└── .github/workflows/build-unsigned-ipa.yml
```

## 三、录制原理（为什么这么设计）

1. `Broadcast Upload Extension` 跑在**独立进程**，主 App 进后台或被杀掉，录制进程仍然活着 → 这就是"后台不掉线"。
2. 扩展进程有内存上限，**不能**在内存里堆 10 分钟原始帧（必被系统杀掉）。所以每 10 秒用 `AVAssetWriter` 落一个 mp4 分片。
3. 每落一片就删掉超出保留窗口的旧片 → 就是你要的"600 秒后自动删除继续录"。
4. 主 App 只做两件事：轮询共享容器算"缓存了多少秒"，以及把最近 N 秒拼成一条 mp4（`AVAssetExportSession` 1080P 预设）。
5. 所有参数（保留秒数 / 码率 / 麦克风）写在 App Group 的 UserDefaults 里，扩展启动时读一次。

## 四、编译出 .ipa（Windows 也能走）

> Windows 无法编译 iOS，必须 macOS。两条路：本机 Mac，或 GitHub Actions 的 macos runner。

### 路线 A：GitHub Actions（推荐，无需 Mac）

1. 把整个 `回溯录屏-iOS` 目录推到一个 GitHub 仓库（保证 `.github/workflows` 在仓库根目录；若放在子目录，需把 workflow 移到根 `.github/workflows/` 并调 `working-directory`）。
2. 仓库 → Actions → 选 `build-unsigned-ipa` → Run workflow。
3. 跑完在 Artifacts 下载：
   - `RetroRecord-unsigned-ipa` → `RetroRecord-unsigned.ipa`（**标准版**，带 App Group，需付费证书或 TrollStore）
   - `RetroRecord-noappgroup-unsigned-ipa` → `RetroRecord-noappgroup-unsigned.ipa`（**全能签版**，不需要 App Group，免费证书即可签名安装）

### 路线 B：本机 macOS

```bash
brew install xcodegen
cd 回溯录屏-iOS
xcodegen generate
open RetroRecord.xcodeproj      # 真机调试用，需在 Signing 里选自己的 Team
```

打未签名 ipa：

```bash
xcodebuild -project RetroRecord.xcodeproj -scheme RetroRecord \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/RetroRecord.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" archive

mkdir -p build/ipa/Payload
cp -R build/RetroRecord.xcarchive/Products/Applications/RetroRecord.app build/ipa/Payload/
cd build/ipa && zip -qry ../RetroRecord-unsigned.ipa Payload
```

## 五、全能签安装（关键一步）

1. 准备证书：**付费个人开发者证书（688/年）或企业证书**。
   - 免费 Apple ID 证书**不支持 App Group**，会导致扩展录得进、主 App 取不出 → 保存功能直接废掉。
2. 在 Apple Developer 后台创建 App Group：`group.com.retro.recorder`，并给三个 App ID 都勾上：
   - `com.retro.recorder`（主 App）
   - `com.retro.recorder.broadcast`（录制扩展）
   - `com.retro.recorder.widget`（灵动岛）
3. 全能签里选择「导入 ipa + 使用证书签名」，**务必确认签名时保留了 entitlements**：
   - 主 App 与 `PlugIns/RecorderExtension.appex` 都要带 `com.apple.security.application-groups = group.com.retro.recorder`
   - 若全能签把 App Group 剔除了，需要在签名设置里手动注入该 entitlement（部分版本叫「注入权限 / 高级签名」）。
4. 装好后首次打开 → 点「开始录制」→ 系统弹层里选中「回溯录制」→ 点「开始录制」。

> 掉签提醒：共享企业证书随时可能被 Apple 吊销，届时 App 直接打不开，需要重新签名安装。长期自用建议付费个人证书。

### 没有付费证书？用「全能签版」（iOS 17~27，不依赖 App Group）

免费 Apple ID 证书签不了 App Group，标准版会退化成"能录、取不出"。针对这个场景 CI 同时产出**全能签版**：

1. 下载 `RetroRecord-noappgroup-unsigned.ipa`，全能签里直接签名安装（免费证书即可，**无需创建 App Group、无需注入任何 entitlements**）。
2. 安装后打开 → 开始录制 → 系统弹层选「回溯录制」。
3. 点「保存最近 N 秒」：主 App 通过系统级 Darwin 通知让录制扩展**自己拼接并直接写入系统相册**，去「照片」App 的最近项目里就能看到。
4. 保底路径：下拉控制中心点红色按钮停止录制，最近一段也会自动存进相册。
5. 界面差异：设置里没有「后台悬浮球」开关（那需要 TrollStore 的 platform-application 权限，全能签拿不到）；「已保存」列表为空是正常的——视频直接进相册，不经过主 App。
6. 代价：保存由扩展进程完成，比标准版慢几秒；相册里可能出现多段（合成失败时的兜底）。

## 六、使用方式

- **保留时长**：默认 600 秒，界面里可输入任意秒数（10–7200）。改完立即写进 App Group，下次起录生效。
- **回溯保存**：点主界面大按钮、或点悬浮球、或点灵动岛胶囊 → 把最近 N 秒拼成一条 mp4，存入 App 内 + 相册。
- **画质**：扩展按设备原生分辨率 + 选定码率录制（原生分辨率普遍 ≥1080P），导出时可选 1080P / 720P / 原生直通。
  1080P / 6Mbps 约 45MB/分钟，600 秒窗口常驻约 450MB。
- **停止**：iOS 不允许 App 代用户停止，下拉控制中心点红色录屏按钮。

## 七、故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 点「开始录制」没反应 | 扩展没被签进去。检查 ipa 里 `Payload/RetroRecord.app/PlugIns/` 是否有两个 appex |
| 系统弹层里没有「回溯录制」 | 扩展 Info.plist 的 `NSExtensionPointIdentifier` 被破坏，或扩展签名失败 |
| 缓存一直是 00:00 | App Group 没生效。用 Xcode 连真机看控制台是否有 `containerURL` 返回 nil |
| 全能签版保存后相册里没有 | 看「诊断」日志：没有 SAVE_REQ = 扩展没收到（确认录制在跑）；PHOTO_FAIL = 相册权限被拒，去系统设置里打开 |
| 全能签版「已保存」列表为空 | 正常。该变体的视频直接进系统相册，不经过主 App 的导出目录 |
| 保存报"还没有缓存到任何画面" | 录制确实没在跑；或锁屏导致扩展被中断 |
| 视频开头黑屏 | 用了「原生直通」导出；改用 1080P 预设（会重编码，切点精确） |
| 录制几分钟就被系统杀掉 | 码率过高或设备内存紧张，降到 4–6 Mbps |

## 八、合规提醒

这不是隐蔽监控工具：状态栏录制指示器全程可见，被录者知情。请仅在自己的设备、或已明确告知并取得同意的场景下使用；录制他人屏幕内容可能涉及隐私与法律风险。
