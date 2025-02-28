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
    
    /// 新增一个标题属性
    @Published var videoTitle: String = "默认标题"

    /// 新增音量属性，持久化保存
    @Published var volume: Float {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "playerVolume")
        }
    }

    static var shared = PlayerViewModel()

    private var playerTimeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

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
        } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            playerState = .loading
        } else {
            // 若既不是 playing 也不是 loading，则判为 paused
            //（更严谨的做法是区分 paused/idle/error 等）
            if case .error(let error) = playerState {
                // 如果之前就已经是 error 状态，保持 error
                playerState = .error(error)
            } else {
                playerState = .paused
            }
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
    private let buttonSize: CGFloat = 30
    private let buttonSpacing: CGFloat = 12
    private let controlsBackgroundCornerRadius: CGFloat = 12

    // 监听取消集合（用于观察 PlayerState 等）
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
        
        viewModel.$videoTitle
                .sink { [weak self] newTitle in
                    self?.titleLabel.stringValue = newTitle
                }
                .store(in: &cancellables)
        
        viewModel.$volume
            .sink { [weak self] newVolume in
                self?.updateVolumeIcon(for: newVolume)
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
        // 可尝试不同材质：.hudWindow, .popover 等
        controlsBackgroundView.material = .hudWindow
        controlsBackgroundView.blendingMode = .withinWindow
        controlsBackgroundView.state = .active  // 显示毛玻璃效果

        controlsBackgroundView.wantsLayer = true
        controlsBackgroundView.layer?.cornerRadius = controlsBackgroundCornerRadius
        controlsBackgroundView.layer?.masksToBounds = true

        // 初始隐藏（缩小 + 透明）
        controlsBackgroundView.alphaValue = 0.0
        controlsBackgroundView.layer?.transform = CATransform3DMakeScale(0.8, 0.8, 1.0)

        // 淡化/去掉边框
        controlsBackgroundView.layer?.borderColor = NSColor.clear.cgColor
        controlsBackgroundView.layer?.borderWidth = 0

        addSubview(controlsBackgroundView)
    }

    // MARK: - 设置控件
    private func setupControls() {
        // 标题标签
        titleLabel = NSTextField(labelWithString: "我的视频标题")
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
//        volumeIcon.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)
        volumeIcon.contentTintColor = .white
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
        updatePlayPauseButtonImage()
        controlsBackgroundView.addSubview(playPauseButton)

        // 画中画按钮
        pipButton = NSButton(title: "", target: self, action: #selector(togglePip))
        pipButton.isBordered = false
        updatePipButtonImage()
        controlsBackgroundView.addSubview(pipButton)
    }

    // 根据播放状态设置播放/暂停图标
    private func updatePlayPauseButtonImage() {
        if viewModel.playerState.isPlaying {
            playPauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        } else {
            playPauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        }
        playPauseButton.contentTintColor = .white
    }

    // 根据画中画状态设置图标
    private func updatePipButtonImage() {
        if viewModel.pipState == .active {
            pipButton.image = NSImage(systemSymbolName: "pip.exit", accessibilityDescription: "Exit PiP")
        } else {
            pipButton.image = NSImage(systemSymbolName: "pip.enter", accessibilityDescription: "Enter PiP")
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
    
    @available(macOS 13.0, *)
    private func updateVolumeIcon(for volume: Float) {
        // 将音量范围限制在 [0, 1]
        let clampedVolume = max(0, min(volume, 1))

        // 注意：要使用 init?(systemSymbolName:variableValue:)
        volumeIcon.image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                                   variableValue: Double(clampedVolume),
                                   accessibilityDescription: nil)
        volumeIcon.contentTintColor = .white
    }

    // MARK: - 布局
    override func layout() {
        super.layout()

        // 播放器图层大小
        playerLayer?.frame = bounds

        // 整个毛玻璃背景的尺寸
        let backgroundWidth: CGFloat = 420
        let backgroundHeight: CGFloat = 110  // 高度多留一些容纳三行

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
        //   顶部留 8px，标题占 20px 高度
        let titleY = backgroundHeight - margin - labelHeight
        titleLabel.frame = NSRect(x: 0, y: titleY, width: backgroundWidth, height: labelHeight)

        // 2. 状态文字（第二行，居中）
        //   距离标题再留 4px
        let statusY = titleY - labelHeight - 4
        statusLabel.frame = NSRect(x: 0, y: statusY, width: backgroundWidth, height: labelHeight)

        // 3. 第三行放音量控件、播放按钮、PiP按钮
        //   距离状态文字再留 8px
        let controlsY = statusY - buttonSize - 8

        // 布局思路：从左到右依次
        //   volumeIcon -> volumeSlider -> playPauseButton -> pipButton
        //   你也可以让其中一些居中
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
        
        playPauseButton.imageScaling = .scaleProportionallyUpOrDown
        pipButton.imageScaling = .scaleProportionallyUpOrDown
        volumeIcon.imageScaling = .scaleProportionallyUpOrDown
        volumeSlider.frame.size.height = 20
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
        // 第一步：把 window 坐标 -> container(self) 坐标
        let locationInSelf = convert(event.locationInWindow, from: nil)
        // 第二步：把 container(self) 坐标 -> controlsBackgroundView 坐标
        let locationInBackground = controlsBackgroundView.convert(locationInSelf, from: self)

        // 若坐标在 background 的 bounds 内，则锁定
        if controlsBackgroundView.bounds.contains(locationInBackground) {
            setBackgroundState(.locked)
        } else {
            // 否则只是进入播放器区域
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

        // 如果已经离开整个播放器区域
        if !bounds.contains(locationInSelf) {
            setBackgroundState(.hidden)
            return
        }

        // 否则只是离开了 background，但还在播放器
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
            // locked 时一直可见，取消定时器并播放显示动画（若之前是 hidden）
            if oldState == .hidden {
                animateShowBackground()
            }
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
            
            Button("切换播放器标题") {
                viewModel.videoTitle = "这是新的标题"
            }
            .keyboardShortcut(",", modifiers: [.command])
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
