import AVFoundation

/// 后台保活：循环播放 0.1 秒静音，让 App 切到后台后进程不被系统挂起，
/// 全局悬浮球才能继续显示，点球后才能在后台跑完保存导出。
///
/// 只在「后台悬浮球」开关打开时运行，关掉即停，不留后台痕迹。
/// 用 .mixWithOthers，不会打断别的 App 正在播的音乐。
enum KeepAlive {
    static let shared = KeepAlive()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // 静音也要占住播放会话，否则后台几秒就被挂起
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frames = AVAudioFrameCount(format.sampleRate * 0.1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames // 全零即静音
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try? engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
        self.engine = engine
        self.player = player
    }

    func stop() {
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
