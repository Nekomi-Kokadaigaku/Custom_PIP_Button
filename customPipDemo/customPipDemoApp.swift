//
//  customPipDemoApp.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-16.
//

import AVKit
import SwiftUI

// MARK: - 播放器状态定义
enum PlayerState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case error(Error)

    // 自定义 Equatable 实现，忽略 error 中的具体信息
    static func ==(lhs: PlayerState, rhs: PlayerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.loading, .loading),
             (.playing, .playing),
             (.paused, .paused):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }
}

// MARK: - 画中画状态
enum PiPState: Equatable {
    case normal
    case entering
    case active
    case exiting
}

// MARK: - 圆角矩形背景的显示状态
/// - hidden: 完全隐藏
/// - transient: 短暂显示（自动隐藏）
/// - locked: 鼠标停留在背景区域，锁定显示
enum BackgroundState {
    case hidden
    case transient
    case locked
}

// MARK: - 播放器视图模型
class PlayerViewModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var playerState: PlayerState = .idle
    @Published private(set) var pipState: PiPState = .normal

    @Published var player: AVPlayer!
    @Published var playerLayer: AVPlayerLayer!
    @Published var pipController: AVPictureInPictureController!

    /// 新增音量属性，持久化保存
    @Published var volume: Float {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "playerVolume")
        }
    }

    static var shared = PlayerViewModel()

    private var playerTimeObserver: Any?

    override init() {
        // 加载保存的音量值，若不存在则默认为 1.0
        if let savedVolume = UserDefaults.standard.object(forKey: "playerVolume") as? Float {
            volume = savedVolume
        } else {
            volume = 1.0
        }

        super.init()

        // 初始化播放器
        let url = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        player = AVPlayer(url: url)
        player.volume = volume

        setupTimeObserver()
        setupPlayerLayer()
    }

    private func setupTimeObserver() {
        // 避免重复添加观察者
        if let observer = playerTimeObserver {
            player.removeTimeObserver(observer)
            playerTimeObserver = nil
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        playerTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.updatePlayingStatus()
        }
    }

    private func setupPlayerLayer() {
        playerLayer = AVPlayerLayer(player: player)
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController.delegate = self
    }

    private func updatePlayingStatus() {
        // 使用 AVPlayer 的 timeControlStatus 来更新状态
        if player.timeControlStatus == .playing {
            playerState = .playing
        } else {
            playerState = .paused
        }
    }

    func play() {
        // 允许从 idle 或 paused 状态播放
        if playerState == .paused || playerState == .idle {
            player.play()
            playerState = .playing
        }
    }

    func pause() {
        guard playerState == .playing else { return }
        player.pause()
        playerState = .paused
    }

    func togglePipMode() {
        switch pipState {
        case .normal:
            pipState = .entering
            pipController.startPictureInPicture()
        case .active:
            pipState = .exiting
            pipController.stopPictureInPicture()
        default:
            break // 正在转换状态时忽略操作
        }
    }

    func switchVideoSource(to urlString: String) {
        guard let url = URL(string: urlString) else {
            playerState = .error(NSError(domain: "Invalid URL", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 URL"]))
            return
        }

        playerState = .loading

        if case .active = pipState {
            pipState = .exiting
            pipController.stopPictureInPicture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.performVideoSourceSwitch(url: url)
            }
        } else {
            performVideoSourceSwitch(url: url)
        }
    }

    private func performVideoSourceSwitch(url: URL) {
        // 清理旧资源
        cleanupResources()

        // 创建新的播放器和相关组件
        player = AVPlayer(url: url)
        player.volume = volume
        setupTimeObserver()
        setupPlayerLayer()

        // 开始播放
        player.play()
        playerState = .playing
    }

    private func cleanupResources() {
        if let observer = playerTimeObserver {
            player.removeTimeObserver(observer)
            playerTimeObserver = nil
        }

        if pipController != nil {
            pipController.stopPictureInPicture()
            pipController = nil
        }

        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - PiP Delegate Methods
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipState = .active
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pipState = .normal
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        pipState = .normal
        playerState = .error(error)
    }

    deinit {
        cleanupResources()
    }
}

// MARK: - 自定义播放器容器视图（NSView）
class PlayerContainerView: NSView {

    // 视图模型
    var viewModel: PlayerViewModel

    // 播放器图层
    var playerLayer: AVPlayerLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let newLayer = playerLayer {
                self.layer?.insertSublayer(newLayer, at: 0)
                newLayer.frame = self.bounds
            }
        }
    }

    // 使用 NSVisualEffectView 替代 NSView 作为圆角背景
    private var controlsBackgroundView: NSVisualEffectView!

    // 播放/暂停按钮
    private var playPauseButton: NSButton!
    // 画中画按钮
    private var pipButton: NSButton!
    // 音量滑块
    private var volumeSlider: NSSlider!

    // 跟踪区域：播放器区域
    private var containerTrackingArea: NSTrackingArea?
    // 跟踪区域：背景区域
    private var backgroundTrackingArea: NSTrackingArea?

    // 背景显示状态
    private var backgroundState: BackgroundState = .hidden

    // 自动隐藏计时器
    private var autoHideTimer: Timer?

    // 自动隐藏延迟（秒），可持久化
    private var autoHideDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(autoHideDelay, forKey: "AutoHideDelayKey")
        }
    }

    // 初始化
    init(frame frameRect: NSRect, viewModel: PlayerViewModel) {
        self.viewModel = viewModel

        // 读取 UserDefaults 中的延迟设置，如无则默认 3 秒
        if let savedDelay = UserDefaults.standard.object(forKey: "AutoHideDelayKey") as? TimeInterval {
            self.autoHideDelay = savedDelay
        } else {
            self.autoHideDelay = 3.0
        }

        super.init(frame: frameRect)

        wantsLayer = true
        // 初始化播放器
        setupPlayerLayer()
        // 初始化控件背景和控件
        setupControlsBackground()
        setupControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 设置播放器图层
    private func setupPlayerLayer() {
        if layer == nil {
            wantsLayer = true
        }
        self.playerLayer = viewModel.playerLayer
    }

    // MARK: - 设置圆角矩形背景 (NSVisualEffectView)
    private func setupControlsBackground() {
        controlsBackgroundView = NSVisualEffectView()
        controlsBackgroundView.material = .hudWindow  // 可根据需要修改
        controlsBackgroundView.blendingMode = .withinWindow
        controlsBackgroundView.state = .active  // 使其显示毛玻璃效果

        // 圆角 + 遮罩
        controlsBackgroundView.wantsLayer = true
        controlsBackgroundView.layer?.cornerRadius = 12.0
        controlsBackgroundView.layer?.masksToBounds = true

        // 初始隐藏（缩小 + 透明）
        controlsBackgroundView.alphaValue = 0.0
        controlsBackgroundView.layer?.transform = CATransform3DMakeScale(0.1, 0.1, 1.0)

        addSubview(controlsBackgroundView)
    }

    // MARK: - 设置控件
    private func setupControls() {
        // 播放/暂停按钮 (SF Symbol)
        playPauseButton = NSButton(title: "", target: self, action: #selector(togglePlayPause))
        playPauseButton.bezelStyle = .texturedRounded
        playPauseButton.isBordered = false
        updatePlayPauseButtonImage() // 设置初始图标
        controlsBackgroundView.addSubview(playPauseButton)

        // 画中画按钮 (SF Symbol)
        pipButton = NSButton(title: "", target: self, action: #selector(togglePip))
        pipButton.bezelStyle = .texturedRounded
        pipButton.isBordered = false
        updatePipButtonImage() // 设置初始图标
        controlsBackgroundView.addSubview(pipButton)

        // 音量滑块
        volumeSlider = NSSlider(value: Double(viewModel.volume),
                                minValue: 0.0,
                                maxValue: 1.0,
                                target: self,
                                action: #selector(volumeChanged))
        controlsBackgroundView.addSubview(volumeSlider)
    }

    // 根据播放状态设置播放/暂停图标
    private func updatePlayPauseButtonImage() {
        if viewModel.playerState.isPlaying {
            // 暂停图标
            playPauseButton.image = NSImage(systemSymbolName: "pause.fill",
                                            accessibilityDescription: "Pause")
        } else {
            // 播放图标
            playPauseButton.image = NSImage(systemSymbolName: "play.fill",
                                            accessibilityDescription: "Play")
        }
    }

    // 根据画中画状态设置图标
    private func updatePipButtonImage() {
        if viewModel.pipState == .active {
            // 退出画中画图标
            // 若 "pip.exit" 不可用，请换其他合适图标
            pipButton.image = NSImage(systemSymbolName: "pip.exit",
                                      accessibilityDescription: "Exit PiP")
        } else {
            // 进入画中画图标
            pipButton.image = NSImage(systemSymbolName: "pip.enter",
                                      accessibilityDescription: "Enter PiP")
        }
    }

    // MARK: - 布局
    override func layout() {
        super.layout()

        // 播放器图层大小
        playerLayer?.frame = bounds

        // 背景大小和位置
        let backgroundWidth: CGFloat = 320
        let backgroundHeight: CGFloat = 70
        let backgroundX = (bounds.width - backgroundWidth) / 2
        let backgroundY: CGFloat = 20  // 距离底部 20
        controlsBackgroundView.frame = NSRect(x: backgroundX, y: backgroundY,
                                              width: backgroundWidth, height: backgroundHeight)

        // 内部控件布局
        let buttonSize: CGFloat = 24
        let buttonY = (backgroundHeight - buttonSize) / 2
        var currentX: CGFloat = 20

        // 播放/暂停按钮位置
        playPauseButton.frame = NSRect(x: currentX, y: buttonY,
                                       width: buttonSize, height: buttonSize)
        currentX += (buttonSize + 20)

        // 画中画按钮位置
        pipButton.frame = NSRect(x: currentX, y: buttonY,
                                 width: buttonSize, height: buttonSize)
        currentX += (buttonSize + 20)

        // 音量滑块位置
        let sliderWidth: CGFloat = 120
        volumeSlider.frame = NSRect(x: currentX, y: buttonY,
                                    width: sliderWidth, height: buttonSize)
    }

    // MARK: - 更新追踪区域
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // 移除旧的追踪区域
        if let area = containerTrackingArea {
            removeTrackingArea(area)
        }
        if let area = backgroundTrackingArea {
            controlsBackgroundView.removeTrackingArea(area)
        }

        // 播放器区域追踪
        containerTrackingArea = NSTrackingArea(rect: bounds,
                                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                               owner: self,
                                               userInfo: nil)
        addTrackingArea(containerTrackingArea!)

        // 背景区域追踪
        backgroundTrackingArea = NSTrackingArea(rect: controlsBackgroundView.bounds,
                                                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                                owner: self,
                                                userInfo: nil)
        controlsBackgroundView.addTrackingArea(backgroundTrackingArea!)
    }

    // MARK: - 鼠标事件
    override func mouseEntered(with event: NSEvent) {
        let locationInWindow = event.locationInWindow
        let locationInBackground = convert(locationInWindow, to: controlsBackgroundView)

        // 如果在背景区域内 -> locked
        if controlsBackgroundView.bounds.contains(locationInBackground) {
            setBackgroundState(.locked)
        } else {
            // 否则是在播放器区域内但不在背景区域 -> transient
            // 仅当当前是 hidden 时需要执行显示动画
            if backgroundState == .hidden {
                setBackgroundState(.transient)
            } else if backgroundState == .locked {
                // 如果原本是 locked，保持 locked 或转 transient？
                // 这里按需求：如果原先是 locked，但鼠标离开背景进入播放器，则转 transient
                setBackgroundState(.transient)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        let locationInWindow = event.locationInWindow
        let locationInSelf = convert(locationInWindow, from: nil)

        // 若鼠标离开整个播放器
        if !bounds.contains(locationInSelf) {
            // 离开播放器区域 -> 直接隐藏
            setBackgroundState(.hidden)
            return
        }

        // 否则说明是离开背景区域，但仍在播放器内
        let locationInBackground = convert(locationInWindow, to: controlsBackgroundView)
        if !controlsBackgroundView.bounds.contains(locationInBackground) {
            // 如果原先是 locked，则转为 transient
            if backgroundState == .locked {
                setBackgroundState(.transient)
            }
        }
    }

    // MARK: - 状态切换
    private func setBackgroundState(_ newState: BackgroundState) {
        // 先取消定时器
        autoHideTimer?.invalidate()
        autoHideTimer = nil

        let oldState = backgroundState
        backgroundState = newState

        switch (oldState, newState) {
        // -> hidden
        case (_, .hidden):
            animateHideBackground()

        // -> transient
        case (.hidden, .transient):
            // 从 hidden 到 transient，需要显示动画
            animateShowBackground()
            startAutoHideTimer()

        case (.locked, .transient),
             (.transient, .transient):
            // 从 locked 到 transient 或在 transient 内刷新，都需要保持可见，但重置定时器
            // 不再重复播放出现动画，以免闪动
            startAutoHideTimer()

        // -> locked
        case (_, .locked):
            // locked 时一直可见，取消定时器并播放显示动画（若之前是 hidden）
            if oldState == .hidden {
                animateShowBackground()
            } else {
                // 如果之前是 transient/locked，已经是显示状态，不重复动画
                // do nothing
            }

        default:
            break
        }
    }

    // MARK: - 动画显示背景
    private func animateShowBackground() {
        let duration: CFTimeInterval = 0.4
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            controlsBackgroundView.animator().alphaValue = 1.0
            // 缩放动画
            let fromTransform = CATransform3DMakeScale(0.1, 0.1, 1.0)
            let toTransform = CATransform3DIdentity
            controlsBackgroundView.layer?.animateTransform(from: fromTransform,
                                                           to: toTransform,
                                                           duration: duration)
        }
    }

    // MARK: - 动画隐藏背景
    private func animateHideBackground() {
        let duration: CFTimeInterval = 0.4
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            controlsBackgroundView.animator().alphaValue = 0.0
            let toTransform = CATransform3DMakeScale(0.1, 0.1, 1.0)
            controlsBackgroundView.layer?.animateTransform(from: controlsBackgroundView.layer?.transform ?? CATransform3DIdentity,
                                                           to: toTransform,
                                                           duration: duration)
        }
    }

    // MARK: - 启动自动隐藏计时器
    private func startAutoHideTimer() {
        autoHideTimer = Timer.scheduledTimer(timeInterval: autoHideDelay,
                                             target: self,
                                             selector: #selector(autoHideTimerFired),
                                             userInfo: nil,
                                             repeats: false)
    }

    @objc private func autoHideTimerFired() {
        // 若当前仍是 transient，则隐藏
        if backgroundState == .transient {
            setBackgroundState(.hidden)
        }
    }

    // MARK: - 控件事件
    @objc private func togglePlayPause() {
        if viewModel.playerState.isPlaying {
            viewModel.pause()
        } else {
            viewModel.play()
        }
        updatePlayPauseButtonImage()
    }

    @objc private func togglePip() {
        viewModel.togglePipMode()
        updatePipButtonImage()
    }

    @objc private func volumeChanged() {
        viewModel.volume = Float(volumeSlider.doubleValue)
    }

    // 在切换视频源后更新 playerLayer
    func updatePlayerLayer() {
        playerLayer?.removeFromSuperlayer()
        self.playerLayer = viewModel.playerLayer
        if let playerLayer = playerLayer {
            layer?.insertSublayer(playerLayer, at: 0)
            playerLayer.frame = bounds
        }
    }
}

// MARK: - CALayer 动画扩展
extension CALayer {
    /// 为 transform 属性做一个从某个值到某个值的动画
    func animateTransform(from: CATransform3D, to: CATransform3D, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // 动画结束后保持最终状态
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        self.add(animation, forKey: "transformAnimation")
        self.transform = to
    }
}

// MARK: - 自定义播放器视图（NSViewRepresentable包装 PlayerContainerView）
struct CustomPlayerView: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeNSView(context: Context) -> NSView {
        let containerView = PlayerContainerView(frame: .zero, viewModel: viewModel)
        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let containerView = nsView as? PlayerContainerView else { return }
        containerView.updatePlayerLayer()
    }
}

// MARK: - 内容视图（SwiftUI）
struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()

    @State var m3u8Link: String = "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8"

    var body: some View {
        VStack {
            // 自定义播放器视图
            CustomPlayerView(viewModel: viewModel)
                .frame(width: 640, height: 360)

            // 输入视频 URL 与切换视频源按钮
            TextField("请输入视频 URL", text: $m3u8Link)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding([.leading, .trailing])

            Button(action: {
                viewModel.switchVideoSource(to: m3u8Link)
            }) {
                Text("切换视频源")
            }
            .padding()
        }
    }
}

extension NSTextView {
    open override var frame: CGRect {
        didSet {
            backgroundColor = .clear
            drawsBackground = true
        }
    }
}
