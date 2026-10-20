import Foundation

/// 主 App 与录制扩展之间的跨进程通道。
///
/// 降级模式下两者各自关在自己的沙盒里，文件传不过去；
/// 但 Darwin 通知（notify_post）是系统级的，不受沙盒限制，
/// 而且通知名本身就是一段字符串 —— 于是把「要保留的秒数」和「内部日志」
/// 编码进通知名里，扩展就能把状态实时回传给主 App 显示。
///
/// 注意：Darwin 通知不能携带 payload，也不能传中文和空格，
/// 所以日志一律用英文短码（SEG_OK、AUTH_denied、PHOTO_FAIL …）。
public enum NotifyBridge {
    public static let savePrefix = "com.retro.recorder.save."
    public static let logPrefix = "com.retro.recorder.log."
    /// 降级模式下扩展读不到主 App 写的配置文件，保留秒数只能靠这条通道同步过去
    public static let configPrefix = "com.retro.recorder.cfg."
    /// 主 App 主动探活：扩展收到就回一串状态。带时间戳后缀，
    /// 避免 notifyd 把连续两次同名通知合并成一次
    public static let pingPrefix = "com.retro.recorder.ping."
    /// 外部触发保存：越狱 tweak / 游戏内悬浮按钮等跨进程入口。
    /// 与 savePrefix 的区别 —— save 是「主 App → 扩展」的内部指令；
    /// trigger 是「任意第三方进程 → 录制扩展」，且扩展收到后无条件导出，
    /// 不看 AppGroup.isShared：触发方无法保证主 App 没被系统挂起。
    public static let triggerPrefix = "com.retro.recorder.trigger."
    /// 游戏内悬浮窗面板直接改码率：外部进程 → 录制扩展。
    /// 与 configPrefix 的区别 —— config 只同步保留时长（主 App → 扩展）；
    /// bitrate 允许任意外部进程改，且扩展收到后立刻切一段新分片让新码率马上生效。
    public static let bitratePrefix = "com.retro.recorder.bitrate."
    /// 游戏内悬浮窗面板直接改输出分辨率上限（高度像素，0 = 原画质）：
    /// 外部进程 → 录制扩展，收到后立刻切一段新分片让新分辨率生效。
    /// 注意只能向下缩，源不足时仍输出源分辨率（放大没有意义）。
    public static let resPrefix = "com.retro.recorder.res."

    // MARK: - 固定回执（外部进程专用）
    //
    // 为什么需要这一组「不带参数的固定名」：
    // 在 iOS 上，CFNotificationCenterAddObserver 对 Darwin 中心传 name = NULL
    // （通配监听所有通知）经常一条都收不到 —— notifyd 只对「被显式注册过的完整通知名」
    // 投递。而 logPrefix 后面跟的是自由文本（TRIG_SAVE_60、SEGS_3 …），根本无法枚举，
    // 所以外部进程（游戏内悬浮窗）过去一直拿不到回执，只能误判成「没在录」。
    //
    // 解决办法：扩展额外广播三条**名字固定**的回执，外部进程按全名注册即可稳定收到。
    public static let ackPrefix = "com.retro.recorder.ack."
    /// 扩展收到了保存指令
    public static let ackTrig = ackPrefix + "trig"
    /// 扩展活着（回答 ping）
    public static let ackPing = ackPrefix + "ping"
    /// 分片已收尾并成功写入相册
    public static let ackDone = ackPrefix + "done"
    /// 写入相册失败（权限被拒 / 没有可用分片）
    public static let ackFail = ackPrefix + "fail"

    // MARK: - 显式注册用的候选名
    //
    // 参数只能编码在通知名里，所以按「界面上真正可能出现的档位」枚举注册：
    // 通配不可靠，就把所有可能的全名都注册一遍。
    public static let secondSteps = [10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 300, 600]
    /// 1...20 Mbps 全枚举，App 里的滑杆能出任意整数值
    public static let bitrateSteps = Array(1...20)
    /// 分辨率上限（高度像素），0 = 原画质
    public static let resSteps = [0, 720, 1080, 1440, 2160]

    public static var triggerNames: [String] { secondSteps.map { triggerPrefix + String($0) } }
    public static var saveNames: [String] { secondSteps.map { savePrefix + String($0) } }
    public static var configNames: [String] { secondSteps.map { configPrefix + String($0) } }
    public static var bitrateNames: [String] { bitrateSteps.map { bitratePrefix + String($0) } }
    public static var resNames: [String] { resSteps.map { resPrefix + String($0) } }
    /// ping 用两个固定名交替，避免 notifyd 把连续两次同名通知合并掉
    public static var pingNames: [String] { [pingPrefix + "a", pingPrefix + "b"] }

    /// 录制扩展打开：日志除广播外再落一份到共享目录，主 App 事后可读。
    /// 主 App 保持 false，避免把自己的日志也混进同一个文件。
    /// 见 ExtLogFile 的说明 —— 主 App 挂起期间收不到 Darwin 通知，只能靠落盘补。
    public static var mirrorToFile = false

    // MARK: - 发送

    private static func post(name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    /// 主 App 通知扩展：把最近 seconds 秒导出到相册
    public static func postSave(seconds: Int) {
        post(name: savePrefix + String(max(seconds, 5)))
    }

    /// 主 App 通知扩展：用户把保留时长改成了 seconds 秒（扩展据此滚动删除旧分片）
    public static func postConfig(retentionSeconds: Int) {
        post(name: configPrefix + String(max(retentionSeconds, 10)))
    }

    /// 主 App / 外部进程探活：扩展如果还活着，会回 PONG + 分片数 + 相册权限。
    /// 两个固定名交替，保证每次 post 都是一条「新」通知
    private static var pingToggle = false
    private static let pingLock = NSLock()

    public static func postPing() {
        pingLock.lock()
        pingToggle.toggle()
        let which = pingToggle ? "a" : "b"
        pingLock.unlock()
        post(name: pingPrefix + which)
    }

    /// 扩展回执：已收到保存指令
    public static func postAckTrig() { post(name: ackTrig) }
    /// 扩展回执：活着（回答 ping）
    public static func postAckPing() { post(name: ackPing) }
    /// 扩展回执：已写入相册
    public static func postAckDone() { post(name: ackDone) }
    /// 扩展回执：写入失败
    public static func postAckFail() { post(name: ackFail) }

    /// 外部进程请求「导出最近 seconds 秒」。由录制扩展接收并执行
    public static func postTrigger(seconds: Int) {
        post(name: triggerPrefix + String(max(seconds, 5)))
    }

    /// 外部进程请求「把码率改成 mbps」。由录制扩展接收，下一段分片生效
    public static func postBitrate(mbps: Int) {
        post(name: bitratePrefix + String(min(max(mbps, 1), 20)))
    }

    /// 外部进程请求「输出分辨率上限改为 heightPx（0 = 原画质）」
    public static func postResCap(heightPx: Int) {
        post(name: resPrefix + String(max(heightPx, 0)))
    }

    /// 任意一侧广播一条日志。字符会被规整成通知名能接受的形态
    public static func postLog(_ raw: String) {
        var text = ""
        for scalar in raw.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                text.unicodeScalars.append(scalar)
            } else {
                text.unicodeScalars.append("_")
            }
            if text.count >= 140 { break }
        }
        guard !text.isEmpty else { return }
        if mirrorToFile { ExtLogFile.append(text) }
        post(name: logPrefix + text)
    }

    // MARK: - 接收

    /// 注册句柄。一定要保存返回值，不用时调用 unobserve，
    /// 否则扩展进程复用时会回调到已释放的 handler 上（野指针崩溃）
    public final class Observation {
        fileprivate let box: LogBox

        fileprivate init(box: LogBox) {
            self.box = box
        }
    }

    private static let lock = NSLock()
    private static var boxes: [LogBox] = []

    public static func observeLog(_ handler: @escaping (String) -> Void) -> Observation {
        // 日志正文是自由文本，枚举不出来，只能靠通配。
        // 主 App 还有一份落盘日志兜底，所以这里收不到也不致命。
        observe(prefix: logPrefix) { handler($0) }
    }

    public static func observeSave(_ handler: @escaping (Double) -> Void) -> Observation {
        observe(prefix: savePrefix, explicit: saveNames) { text in
            handler(Double(text) ?? 600)
        }
    }

    public static func observeConfig(_ handler: @escaping (Double) -> Void) -> Observation {
        observe(prefix: configPrefix, explicit: configNames) { text in
            handler(Double(text) ?? 600)
        }
    }

    public static func observePing(_ handler: @escaping () -> Void) -> Observation {
        observe(prefix: pingPrefix, explicit: pingNames) { _ in
            handler()
        }
    }

    public static func observeTrigger(_ handler: @escaping (Double) -> Void) -> Observation {
        observe(prefix: triggerPrefix, explicit: triggerNames) { text in
            handler(Double(text) ?? 60)
        }
    }

    public static func observeBitrate(_ handler: @escaping (Double) -> Void) -> Observation {
        observe(prefix: bitratePrefix, explicit: bitrateNames) { text in
            handler(Double(text) ?? 6)
        }
    }

    public static func observeResCap(_ handler: @escaping (Double) -> Void) -> Observation {
        observe(prefix: resPrefix, explicit: resNames) { text in
            handler(Double(text) ?? 0)
        }
    }

    /// 扩展 → 外部进程的三条固定回执。名字是固定的，直接按全名注册
    public static func observeAck(onTrig: @escaping () -> Void,
                                  onPing: @escaping () -> Void,
                                  onDone: @escaping () -> Void,
                                  onFail: @escaping () -> Void) -> Observation {
        observe(prefix: ackPrefix, explicit: [ackTrig, ackPing, ackDone, ackFail]) { text in
            switch text {
            case "trig": onTrig()
            case "ping": onPing()
            case "done": onDone()
            case "fail": onFail()
            default: break
            }
        }
    }

    public static func unobserve(_ observation: Observation) {
        lock.lock()
        if let index = boxes.firstIndex(where: { $0 === observation.box }) {
            boxes.remove(at: index)
        }
        lock.unlock()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let ptr = Unmanaged.passUnretained(observation.box).toOpaque()
        // name / object 都传 nil = 摘掉这个 observer 句柄上的全部注册，
        // 省得为每个名字再调一次（AddObserver 要 CFString、RemoveObserver 要
        // CFNotificationName，两个 API 的类型还不一样，逐个摘容易写错）
        CFNotificationCenterRemoveObserver(center, ptr, nil, nil)
    }

    /// 注册观察。
    ///
    /// - important: iOS 的 Darwin 通知中心对 name = NULL 的通配注册**经常不投递**，
    ///   所以只要给了 explicit，就只按完整通知名逐个注册（保证收得到）；
    ///   没给 explicit（比如自由文本的日志）才退回通配。
    ///   两种不会同时注册 —— 同时注册会让同一次 post 触发多遍回调。
    private static func observe(prefix: String,
                                explicit: [String] = [],
                                handler: @escaping (String) -> Void) -> Observation {
        let box = LogBox(prefix: prefix, handler: handler, names: explicit)
        lock.lock()
        boxes.append(box)
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let ptr = Unmanaged.passUnretained(box).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let text = name.rawValue as String
            let box = Unmanaged<LogBox>.fromOpaque(observer).takeUnretainedValue()
            guard text.hasPrefix(box.prefix) else { return }
            box.handler(String(text.dropFirst(box.prefix.count)))
        }

        if explicit.isEmpty {
            CFNotificationCenterAddObserver(center, ptr, callback, nil, nil, .deliverImmediately)
        } else {
            for name in explicit {
                // 注意：AddObserver 的 name 参数是 CFString（Post 才是 CFNotificationName）
                CFNotificationCenterAddObserver(
                    center, ptr, callback, name as CFString, nil, .deliverImmediately
                )
            }
        }
        return Observation(box: box)
    }
}

private final class LogBox {
    let prefix: String
    let handler: (String) -> Void
    let names: [String]

    init(prefix: String, handler: @escaping (String) -> Void, names: [String]) {
        self.prefix = prefix
        self.handler = handler
        self.names = names
    }
}

/// 日志落点。故意不做成 MainActor 隔离：
/// Darwin 回调在任意线程上触发，这里用锁保护，主 App 的轮询去取快照即可。
public final class LogSink {
    public static let shared = LogSink()

    private let lock = NSLock()
    private var lines: [String] = []

    private init() {}

    public func append(_ raw: String) {
        let stamp = LogSink.clockText()
        lock.lock()
        lines.append("\(stamp) \(raw)")
        if lines.count > 60 {
            lines = Array(lines.suffix(60))
        }
        lock.unlock()
    }

    public var snapshot: [String] {
        lock.lock()
        let value = lines
        lock.unlock()
        return value
    }

    public func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    private static func clockText() -> String {
        let total = Int(Date().timeIntervalSince1970) % 86400
        let hour = total / 3600
        let minute = (total % 3600) / 60
        let second = total % 60
        return String(format: "%02d:%02d:%02d", hour, minute, second)
    }
}

/// 把 Darwin 通知收到的日志接进 LogSink。主 App 与扩展共用
public enum LogBridge {
    private static var observation: NotifyBridge.Observation?

    public static func start() {
        guard observation == nil else { return }
        observation = NotifyBridge.observeLog { text in
            LogSink.shared.append(text)
        }
    }

    public static func stop() {
        if let observation {
            NotifyBridge.unobserve(observation)
        }
        observation = nil
    }

    /// 本地也记一条，方便区分是主 App 发的还是扩展发的
    public static func local(_ text: String) {
        LogSink.shared.append("APP " + text)
    }
}
