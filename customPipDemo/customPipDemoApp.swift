//
//  customPipDemoApp.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-16.
//

import AVKit
import SwiftUI

import Combine

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

    /// 音量属性，持久化保存
    @Published var volume: Float {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "playerVolume")
        }
    }

    /// 新增：可外部修改的标题
    @Published var videoTitle: String = "默认标题"

    static var shared = PlayerViewModel()

    private var playerTimeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    // 在 init() 中
    override init() {
        // 加载保存的音量值...
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

        // 【新增】设置直播相关属性：确保播放最新片段
        if let item = player.currentItem {
            if #available(macOS 11.0, *) {
                item.automaticallyPreservesTimeOffsetFromLive = true
            }
        }
        player.automaticallyWaitsToMinimizeStalling = false

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
        } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            playerState = .loading
        } else {
            if case .error(let error) = playerState {
                // 如果之前就是错误状态，保持
                playerState = .error(error)
            } else {
                playerState = .paused
            }
        }
    }

    // MARK: - 播放控制
    func play() {
        if playerState == .paused || playerState == .idle {
            // 如果当前 AVPlayerItem 是直播（duration 为无限大），则先 seek 到 live edge
            if let currentItem = player.currentItem, currentItem.duration.isIndefinite {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self,
                          let timeRange = self.player.currentItem?.seekableTimeRanges.last?.timeRangeValue else {
                        self?.player.play()
                        self?.playerState = .playing
                        return
                    }
                    let livePosition = CMTimeAdd(timeRange.start, timeRange.duration)
                    self.player.seek(to: livePosition, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        self.player.play()
                        self.playerState = .playing
                    }
                }
            } else {
                player.play()
                playerState = .playing
            }
        }
    }


    func pause() {
        guard playerState == .playing else { return }
        player.pause()
        playerState = .paused
    }

    // MARK: - 画中画
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // 当用户从 PiP 返回时，将状态重置为 normal 并恢复主界面
        pipState = .normal
        completionHandler(true)
    }
    
    func togglePipMode() {
        // 如果当前处于 transitional 状态则忽略
        if pipState == .entering || pipState == .exiting { return }
        
        if pipState == .normal {
            pipState = .entering
            pipController.startPictureInPicture()
        } else if pipState == .active {
            pipState = .exiting
            pipController.stopPictureInPicture()
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        pipState = .active
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        pipState = .normal
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        pipState = .normal
        playerState = .error(error)
    }

    // MARK: - 切换视频源
    func switchVideoSource(to urlString: String) {
        guard let url = URL(string: urlString) else {
            playerState = .error(NSError(domain: "Invalid URL", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 URL"]))
            return
        }

        playerState = .loading

        if pipState == .active {
            pipState = .exiting
            pipController.stopPictureInPicture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.performVideoSourceSwitch(url: url)
            }
        } else {
            performVideoSourceSwitch(url: url)
        }
    }

    private func performVideoSourceSwitch(url: URL) {
        // 清理旧资源
        cleanupResources()

        // 创建新的播放器及相关组件
        player = AVPlayer(url: url)
        player.volume = volume
        setupTimeObserver()
        setupPlayerLayer()
        
        // 确保切换后 pipState 重置为 normal
        pipState = .normal

        // 延迟一段时间，让 currentItem 有时间加载 seekableTimeRanges
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self,
                  let currentItem = self.player.currentItem,
                  let timeRange = currentItem.seekableTimeRanges.last?.timeRangeValue else {
                // 如果没有拿到 seekableTimeRanges，则直接播放
                self?.player.play()
                self?.playerState = .playing
                return
            }
            // 计算最新位置：livePosition = range.start + range.duration
            let livePosition = CMTimeAdd(timeRange.start, timeRange.duration)
            self.player.seek(to: livePosition, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                self.player.play()
                self.playerState = .playing
            }
        }
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

    // 毛玻璃背景视图
    private var controlsBackgroundView: NSVisualEffectView!

    // 标题标签
    private var titleLabel: NSTextField!
    // 状态文字
    private var statusLabel: NSTextField!

    // 音量图标
    private var volumeIcon: NSImageView!
    // 音量滑块
    private var volumeSlider: NSSlider!

    // 播放/暂停按钮
    private var playPauseButton: NSButton!
    // 画中画按钮
    private var pipButton: NSButton!

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

    // UI 改进相关常量
    private let buttonSize: CGFloat = 44
    private let buttonSpacing: CGFloat = 12
    private let controlsBackgroundCornerRadius: CGFloat = 12

    // 监听取消集合（用于观察 PlayerState、volume、videoTitle、pipState 等）
    private var cancellables = Set<AnyCancellable>()

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

        // 监听 playerState，动态更新状态文字
        viewModel.$playerState
            .sink { [weak self] state in
                self?.updateStatusLabel(for: state)
            }
            .store(in: &cancellables)

        viewModel.$playerState
            .sink { [weak self] state in
                self?.updatePlayPauseButtonImage()
            }
            .store(in: &cancellables)

        // 监听 volume，动态更新音量图标
        viewModel.$volume
            .sink { [weak self] newVolume in
                self?.updateVolumeIcon(for: newVolume)
            }
            .store(in: &cancellables)

        // 监听 videoTitle，更新标题
        viewModel.$videoTitle
            .sink { [weak self] newTitle in
                self?.titleLabel.stringValue = newTitle
            }
            .store(in: &cancellables)

        // 监听 pipState，更新画中画按钮图标
        viewModel.$pipState
            .sink { [weak self] _ in
                self?.updatePipButtonImage()
            }
            .store(in: &cancellables)
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
        controlsBackgroundView.material = .hudWindow
        controlsBackgroundView.blendingMode = .withinWindow
        controlsBackgroundView.state = .active

        controlsBackgroundView.wantsLayer = true
        controlsBackgroundView.layer?.cornerRadius = controlsBackgroundCornerRadius
        controlsBackgroundView.layer?.masksToBounds = true

        // 初始隐藏（缩小 + 透明）
        controlsBackgroundView.alphaValue = 0.0
        controlsBackgroundView.layer?.transform = CATransform3DMakeScale(0.8, 0.8, 1.0)

        // 去掉/淡化边框
        controlsBackgroundView.layer?.borderColor = NSColor.clear.cgColor
        controlsBackgroundView.layer?.borderWidth = 0

        addSubview(controlsBackgroundView)
    }

    // MARK: - 设置控件
    private func setupControls() {
        // 标题标签
        titleLabel = NSTextField(labelWithString: viewModel.videoTitle)
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        controlsBackgroundView.addSubview(titleLabel)

        // 状态文字
        statusLabel = NSTextField(labelWithString: "未开始播放")
        statusLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        controlsBackgroundView.addSubview(statusLabel)

        // 音量图标
        volumeIcon = NSImageView()
        // 不要在这里固定图标，后面用 variableValue 动态更新
        volumeIcon.imageScaling = .scaleProportionallyUpOrDown
        controlsBackgroundView.addSubview(volumeIcon)

        // 音量滑块
        volumeSlider = NSSlider(value: Double(viewModel.volume),
                                minValue: 0.0,
                                maxValue: 1.0,
                                target: self,
                                action: #selector(volumeChanged))
        controlsBackgroundView.addSubview(volumeSlider)

        // 播放/暂停按钮
        playPauseButton = NSButton(title: "", target: self, action: #selector(togglePlayPause))
        playPauseButton.isBordered = false
        playPauseButton.imageScaling = .scaleProportionallyUpOrDown
        updatePlayPauseButtonImage()
        controlsBackgroundView.addSubview(playPauseButton)

        // 画中画按钮
        pipButton = NSButton(title: "", target: self, action: #selector(togglePip))
        pipButton.isBordered = false
        pipButton.imageScaling = .scaleProportionallyUpOrDown
        updatePipButtonImage()
        controlsBackgroundView.addSubview(pipButton)
    }

    // MARK: - 动态更新 UI

    private func updatePlayPauseButtonImage() {
        if viewModel.playerState.isPlaying {
            playPauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        } else {
            playPauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        }
        playPauseButton.contentTintColor = .white
    }

    private func updatePipButtonImage() {
        // 当状态为 active 或 entering 时，均显示退出图标
        if viewModel.pipState == .active || viewModel.pipState == .entering {
            pipButton.image = AVPictureInPictureController.pictureInPictureButtonStopImage
        } else {
            pipButton.image = AVPictureInPictureController.pictureInPictureButtonStartImage
        }
        pipButton.contentTintColor = .white
    }

    // 动态更新状态文字
    private func updateStatusLabel(for state: PlayerState) {
        switch state {
        case .idle, .paused:
            statusLabel.stringValue = "未开始播放"
        case .playing:
            statusLabel.stringValue = "播放中"
        case .loading:
            statusLabel.stringValue = "加载中"
        case .error(_):
            statusLabel.stringValue = "播放出错"
        }
        updatePlayPauseButtonImage()
    }

    /// 使用 variableValue 来动态显示不同波浪数 (macOS 13+)
    private func updateVolumeIcon(for volume: Float) {
        // 将音量范围限制在 [0, 1]
        let clampedVolume = max(0, min(volume, 1))
        if #available(macOS 13.0, *) {
            volumeIcon.image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                                       variableValue: Double(clampedVolume),
                                       accessibilityDescription: nil)
        } else {
            // 如果要兼容老系统，可以简单用 speaker.wave.3.fill
            volumeIcon.image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                                       accessibilityDescription: nil)
        }
        volumeIcon.contentTintColor = .white
    }

    // MARK: - 布局
    override func layout() {
        super.layout()

        // 播放器图层大小
        playerLayer?.frame = bounds

        // 整个毛玻璃背景的尺寸
        let backgroundWidth: CGFloat = 420
        let backgroundHeight: CGFloat = 110  // 高度留够容纳三行

        // 背景位置：水平居中，距离底部 20
        let backgroundX = (bounds.width - backgroundWidth) / 2
        let backgroundY: CGFloat = 20
        controlsBackgroundView.frame = NSRect(x: backgroundX, y: backgroundY,
                                              width: backgroundWidth, height: backgroundHeight)

        // 修复缩放中心：anchorPoint = (0.5, 0.5)
        if let layer = controlsBackgroundView.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: controlsBackgroundView.frame.midX,
                                     y: controlsBackgroundView.frame.midY)
        }

        // 开始排版内部控件
        let margin: CGFloat = 8
        let labelHeight: CGFloat = 20

        // 1. 标题标签（第一行，居中）
        let titleY = backgroundHeight - margin - labelHeight
        titleLabel.frame = NSRect(x: 0, y: titleY, width: backgroundWidth, height: labelHeight)

        // 2. 状态文字（第二行，居中）
        let statusY = titleY - labelHeight - 4
        statusLabel.frame = NSRect(x: 0, y: statusY, width: backgroundWidth, height: labelHeight)

        // 3. 第三行放音量控件、播放按钮、PiP按钮
        let controlsY = statusY - buttonSize - 8
        var currentX = margin

        volumeIcon.frame = NSRect(x: currentX,
                                  y: controlsY,
                                  width: buttonSize, height: buttonSize)
        currentX += (buttonSize + buttonSpacing)

        let sliderWidth: CGFloat = 100
        volumeSlider.frame = NSRect(x: currentX,
                                    y: controlsY,
                                    width: sliderWidth, height: buttonSize)
        currentX += (sliderWidth + buttonSpacing)

        playPauseButton.frame = NSRect(x: currentX,
                                       y: controlsY,
                                       width: buttonSize, height: buttonSize)
        currentX += (buttonSize + buttonSpacing)

        pipButton.frame = NSRect(x: currentX,
                                 y: controlsY,
                                 width: buttonSize, height: buttonSize)
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
                                               options: [.mouseEnteredAndExited,
                                                         .activeInKeyWindow,
                                                         .inVisibleRect],
                                               owner: self,
                                               userInfo: nil)
        addTrackingArea(containerTrackingArea!)

        // 背景区域追踪
        backgroundTrackingArea = NSTrackingArea(rect: controlsBackgroundView.bounds,
                                                options: [.mouseEnteredAndExited,
                                                          .activeInKeyWindow,
                                                          .inVisibleRect],
                                                owner: self,
                                                userInfo: nil)
        controlsBackgroundView.addTrackingArea(backgroundTrackingArea!)
    }

    // MARK: - 鼠标事件
    override func mouseEntered(with event: NSEvent) {
        // 两步转换：window -> self -> controlsBackgroundView
        let locationInSelf = convert(event.locationInWindow, from: nil)
        let locationInBackground = controlsBackgroundView.convert(locationInSelf, from: self)

        // 如果在背景区域内 -> locked
        if controlsBackgroundView.bounds.contains(locationInBackground) {
            setBackgroundState(.locked)
        } else {
            // 否则是在播放器区域内 -> transient
            if backgroundState == .hidden {
                setBackgroundState(.transient)
            } else if backgroundState == .locked {
                setBackgroundState(.transient)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        let locationInSelf = convert(event.locationInWindow, from: nil)
        let locationInBackground = controlsBackgroundView.convert(locationInSelf, from: self)

        // 若鼠标离开整个播放器
        if !bounds.contains(locationInSelf) {
            setBackgroundState(.hidden)
            return
        }

        // 否则说明是离开背景区域，但仍在播放器内
        if !controlsBackgroundView.bounds.contains(locationInBackground) {
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
            animateShowBackground()
            startAutoHideTimer()

        case (.locked, .transient),
             (.transient, .transient):
            // 需要保持可见，但重置定时器
            startAutoHideTimer()

        // -> locked
        case (_, .locked):
            if oldState == .hidden {
                animateShowBackground()
            }

        default:
            break
        }
    }

    // MARK: - 动画显示背景
    private func animateShowBackground() {
        let duration: CFTimeInterval = 0.3
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            controlsBackgroundView.animator().alphaValue = 1.0
            let fromTransform = CATransform3DMakeScale(0.8, 0.8, 1.0)
            let toTransform = CATransform3DIdentity
            controlsBackgroundView.layer?.animateTransform(from: fromTransform,
                                                           to: toTransform,
                                                           duration: duration)
        }
    }

    // MARK: - 动画隐藏背景
    private func animateHideBackground() {
        let duration: CFTimeInterval = 0.3
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            controlsBackgroundView.animator().alphaValue = 0.0
            let toTransform = CATransform3DMakeScale(0.8, 0.8, 1.0)
            let currentTransform = controlsBackgroundView.layer?.transform ?? CATransform3DIdentity
            controlsBackgroundView.layer?.animateTransform(from: currentTransform,
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
        // 这里也可以手动更新，但实际上我们在 sink 里也会更新
        updatePlayPauseButtonImage()
    }

    @objc private func togglePip() {
        viewModel.togglePipMode()
        // updatePipButtonImage() 不再需要手动，因为有 sink 订阅 pipState
    }

    @objc private func volumeChanged() {
        viewModel.volume = Float(volumeSlider.doubleValue)
        // 不需要手动 updateVolumeIcon()，也会触发 sink
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

            HStack {
                Button("切换视频源") {
                    viewModel.switchVideoSource(to: m3u8Link)
                }
                Button("切换播放器标题") {
                    viewModel.videoTitle = "这是新的标题"
                }
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


#Preview {
    ContentView()
}
