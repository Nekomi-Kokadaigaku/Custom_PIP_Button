//
//  customPipDemoApp.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-16.
//  修改日期: 2025-03-01
//

import AVKit
import SwiftUI
import Combine
import Symbols  // 确保引入 Symbols 框架以使用 symbolEffect API

// MARK: - 播放器状态定义
enum PlayerState: Equatable {
    case idle, loading, playing, paused, error(Error)
    static func ==(lhs: PlayerState, rhs: PlayerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.playing, .playing), (.paused, .paused):
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
    case normal, entering, active, exiting
}

// MARK: - 圆角矩形背景显示状态
enum BackgroundState {
    case hidden, transient, locked
}

// MARK: - 播放器视图模型
class PlayerViewModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var playerState: PlayerState = .idle
    @Published private(set) var pipState: PiPState = .normal

    @Published var player: AVPlayer!
    @Published var playerLayer: AVPlayerLayer!
    @Published var pipController: AVPictureInPictureController!

    // 音量属性封装，通过 getter/setter 统一读写 UserDefaults
    @Published var volume: Float {
        didSet {
            // 当音量不为 0 时，记录上一次的非 0 音量
            if volume > 0 {
                lastNonZeroVolume = volume
            }
            player.volume = volume
            saveVolume(volume)
        }
    }
    // 保存上一次非 0 的音量
    private var lastNonZeroVolume: Float = 1.0
    var lastNonZero: Float { lastNonZeroVolume }

    // 合并后的标题与状态文本
    @Published var videoTitle: String = ""

    static var shared = PlayerViewModel()

    private var playerTimeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        self.volume = PlayerViewModel.loadVolume() ?? 1.0
        super.init()

        // 初始化播放器
        let url = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        player = AVPlayer(url: url)
        player.volume = volume

        // 设置直播相关属性
        if let item = player.currentItem, #available(macOS 11.0, *) {
            item.automaticallyPreservesTimeOffsetFromLive = true
        }
        player.automaticallyWaitsToMinimizeStalling = false

        setupTimeObserver()
        setupPlayerLayer()
    }

    // MARK: - UserDefaults 读写
    private static func loadVolume() -> Float? {
        return UserDefaults.standard.object(forKey: "playerVolume") as? Float
    }
    private func saveVolume(_ volume: Float) {
        UserDefaults.standard.set(volume, forKey: "playerVolume")
    }

    // MARK: - 周期性时间观察者
    private func setupTimeObserver() {
        if let observer = playerTimeObserver {
            player.removeTimeObserver(observer)
            playerTimeObserver = nil
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        playerTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.updatePlayingStatus()
        }
    }

    // MARK: - 播放器图层与 PiP 控制器初始化
    private func setupPlayerLayer() {
        playerLayer = AVPlayerLayer(player: player)
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController.delegate = self
    }

    private func updatePlayingStatus() {
        switch player.timeControlStatus {
        case .playing:
            playerState = .playing
        case .waitingToPlayAtSpecifiedRate:
            playerState = .loading
        default:
            if case .error(let error) = playerState {
                playerState = .error(error)
            } else {
                playerState = .paused
            }
        }
    }

    // MARK: - 播放控制
    func play() {
        if playerState == .paused || playerState == .idle {
            if let currentItem = player.currentItem, currentItem.duration.isIndefinite {
                if let timeRange = currentItem.seekableTimeRanges.last?.timeRangeValue {
                    let livePosition = CMTimeAdd(timeRange.start, timeRange.duration)
                    player.seek(to: livePosition, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        self?.player.play()
                        self?.playerState = .playing
                    }
                } else {
                    player.play()
                    playerState = .playing
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

    // MARK: - 画中画控制
    func togglePipMode() {
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

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        pipState = .normal
        playerState = .error(error)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        pipState = .normal
        completionHandler(true)
    }

    // MARK: - 视频源切换
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
        cleanupResources()
        player = AVPlayer(url: url)
        player.volume = volume
        setupTimeObserver()
        setupPlayerLayer()
        pipState = .normal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self,
                  let currentItem = self.player.currentItem,
                  let timeRange = currentItem.seekableTimeRanges.last?.timeRangeValue else {
                self?.player.play()
                self?.playerState = .playing
                return
            }
            let livePosition = CMTimeAdd(timeRange.start, timeRange.duration)
            self.player.seek(to: livePosition, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                self.player.play()
                self.playerState = .playing
            }
        }
    }

    // MARK: - 资源清理
    private func cleanupResources() {
        defer {
            player.replaceCurrentItem(with: nil)
        }
        if let observer = playerTimeObserver {
            player.removeTimeObserver(observer)
            playerTimeObserver = nil
        }
        if pipController != nil {
            pipController.stopPictureInPicture()
            pipController = nil
        }
        player.pause()
    }

    deinit {
        cleanupResources()
    }
}

// MARK: - 自定义播放器容器视图（NSView）
class PlayerContainerView: NSView {

    var viewModel: PlayerViewModel
    var playerLayer: AVPlayerLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let newLayer = playerLayer {
                self.layer?.insertSublayer(newLayer, at: 0)
                newLayer.frame = self.bounds
            }
        }
    }

    // 合并后的 infoLabel（显示标题和状态）
    private var infoLabel: NSTextField!

    private var volumeIcon: NSImageView!
    private var volumeSlider: NSSlider!
    private var playPauseButton: NSButton!
    private var pipButton: NSButton!

    private var controlsBackgroundView: NSVisualEffectView!
    private var containerTrackingArea: NSTrackingArea?
    private var backgroundTrackingArea: NSTrackingArea?

    private var backgroundState: BackgroundState = .hidden
    private var autoHideTimer: Timer?

    // 自动隐藏延时
    private var autoHideDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(autoHideDelay, forKey: "AutoHideDelayKey")
        }
    }

    // 常量配置
    private let buttonSize: CGFloat = 32
    private let buttonSpacing: CGFloat = 12
    private let controlsBackgroundCornerRadius: CGFloat = 12

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化
    init(frame frameRect: NSRect, viewModel: PlayerViewModel) {
        self.viewModel = viewModel
        if let savedDelay = UserDefaults.standard.object(forKey: "AutoHideDelayKey") as? TimeInterval {
            self.autoHideDelay = savedDelay
        } else {
            self.autoHideDelay = 3.0
        }
        super.init(frame: frameRect)
        wantsLayer = true

        setupPlayerLayer()
        setupControlsBackground()
        setupControls()
        setupConstraints()
        bindViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 播放器图层设置
    private func setupPlayerLayer() {
        if layer == nil { wantsLayer = true }
        self.playerLayer = viewModel.playerLayer
    }

    // MARK: - 控件背景设置
    private func setupControlsBackground() {
        controlsBackgroundView = NSVisualEffectView()
        controlsBackgroundView.material = .hudWindow
        controlsBackgroundView.blendingMode = .withinWindow
        controlsBackgroundView.state = .active
        controlsBackgroundView.wantsLayer = true
        controlsBackgroundView.layer?.cornerRadius = controlsBackgroundCornerRadius
        controlsBackgroundView.layer?.masksToBounds = true
        controlsBackgroundView.alphaValue = 0.0
        controlsBackgroundView.layer?.transform = CATransform3DMakeScale(0.8, 0.8, 1.0)
        controlsBackgroundView.layer?.borderColor = NSColor.clear.cgColor
        controlsBackgroundView.layer?.borderWidth = 0
        controlsBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlsBackgroundView)
    }

    // MARK: - 初始化控件
    private func setupControls() {
        // infoLabel：合并显示标题与状态
        infoLabel = NSTextField(labelWithString: "未开始播放")
        infoLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        infoLabel.textColor = .white
        infoLabel.alignment = .center
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        controlsBackgroundView.addSubview(infoLabel)

        // 音量图标：使用 NSImageView，添加点击手势以实现静音/恢复
        volumeIcon = NSImageView()
        volumeIcon.imageScaling = .scaleProportionallyUpOrDown
        volumeIcon.translatesAutoresizingMaskIntoConstraints = false
        controlsBackgroundView.addSubview(volumeIcon)
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(volumeIconClicked))
        volumeIcon.addGestureRecognizer(clickGesture)
        volumeIcon.wantsLayer = true

        // 音量滑块
        volumeSlider = NSSlider(value: Double(viewModel.volume),
                                minValue: 0.0,
                                maxValue: 1.0,
                                target: self,
                                action: #selector(volumeChanged))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        controlsBackgroundView.addSubview(volumeSlider)

        // 播放/暂停按钮
        playPauseButton = NSButton(title: "", target: self, action: #selector(togglePlayPause))
        playPauseButton.isBordered = false
        playPauseButton.imageScaling = .scaleProportionallyUpOrDown
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        updatePlayPauseButtonImage()
        controlsBackgroundView.addSubview(playPauseButton)

        // 画中画按钮
        pipButton = NSButton(title: "", target: self, action: #selector(togglePip))
        pipButton.isBordered = false
        pipButton.imageScaling = .scaleProportionallyUpOrDown
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        updatePipButtonImage()
        controlsBackgroundView.addSubview(pipButton)
    }

    // MARK: - 添加 Auto Layout 约束
    private func setupConstraints() {
        NSLayoutConstraint.activate([
            controlsBackgroundView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            controlsBackgroundView.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -20),
            controlsBackgroundView.widthAnchor.constraint(equalToConstant: 420),
            controlsBackgroundView.heightAnchor.constraint(equalToConstant: 80)
        ])

        NSLayoutConstraint.activate([
            playPauseButton.centerXAnchor.constraint(equalTo: controlsBackgroundView.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsBackgroundView.centerYAnchor, constant: -8),
            playPauseButton.widthAnchor.constraint(equalToConstant: buttonSize),
            playPauseButton.heightAnchor.constraint(equalToConstant: buttonSize),
        ])

        NSLayoutConstraint.activate([
            volumeIcon.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            volumeIcon.leadingAnchor.constraint(equalTo: controlsBackgroundView.leadingAnchor, constant: 16),
            volumeIcon.widthAnchor.constraint(equalToConstant: 24),
            volumeIcon.heightAnchor.constraint(equalToConstant: 24),

            volumeSlider.centerYAnchor.constraint(equalTo: volumeIcon.centerYAnchor),
            volumeSlider.leadingAnchor.constraint(equalTo: volumeIcon.trailingAnchor, constant: 8),
            volumeSlider.widthAnchor.constraint(equalToConstant: 100)
        ])

        NSLayoutConstraint.activate([
            pipButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            pipButton.trailingAnchor.constraint(equalTo: controlsBackgroundView.trailingAnchor, constant: -16),
            pipButton.widthAnchor.constraint(equalToConstant: 24),
            pipButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: playPauseButton.bottomAnchor, constant: 8),
            infoLabel.centerXAnchor.constraint(equalTo: playPauseButton.centerXAnchor)
        ])
    }

    // MARK: - 绑定 ViewModel
    private func bindViewModel() {
        viewModel.$playerState
            .sink { [weak self] _ in
                self?.updateInfoLabel()
                self?.updatePlayPauseButtonImage()
            }
            .store(in: &cancellables)

        viewModel.$videoTitle
            .sink { [weak self] _ in
                self?.updateInfoLabel()
            }
            .store(in: &cancellables)

        viewModel.$volume
            .sink { [weak self] newVolume in
                self?.updateVolumeIcon(for: newVolume)
            }
            .store(in: &cancellables)

        viewModel.$pipState
            .sink { [weak self] _ in
                self?.updatePipButtonImage()
            }
            .store(in: &cancellables)
    }

    // MARK: - 更新 infoLabel 显示逻辑
    private func updateInfoLabel() {
        switch viewModel.playerState {
        case .playing:
            infoLabel.stringValue = viewModel.videoTitle.isEmpty ? "正在播放" : viewModel.videoTitle
        case .idle, .paused:
            infoLabel.stringValue = "未开始播放"
        case .loading:
            infoLabel.stringValue = "加载中"
        case .error(_):
            infoLabel.stringValue = "播放出错"
        }
    }

    private func updatePlayPauseButtonImage() {
        if viewModel.playerState.isPlaying {
            playPauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        } else {
            playPauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        }
        playPauseButton.contentTintColor = .white
    }

    private func updatePipButtonImage() {
        if viewModel.pipState == .active || viewModel.pipState == .entering {
            pipButton.image = AVPictureInPictureController.pictureInPictureButtonStopImage
        } else {
            pipButton.image = AVPictureInPictureController.pictureInPictureButtonStartImage
        }
        pipButton.contentTintColor = .white
    }

    // MARK: - 使用 symbolEffect 更新音量图标
    private func updateVolumeIcon(for volume: Float) {
        let clampedVolume = max(0, min(volume, 1))

        if clampedVolume == 1.0 {
            // 当音量达到最大时，设置为 speaker.wave.3.fill 并触发 Bounce 效果
            let image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
            volumeIcon.image = image
            volumeIcon.contentTintColor = .white
            // 使用 symbolEffect API 触发 Bounce 效果
            volumeIcon.addSymbolEffect(.bounce)
        } else if clampedVolume == 0 {
            // 当音量为 0 时，用 Replace 动画替换为 speaker.slash.fill
            let newImage = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
            volumeIcon.setSymbolImage(newImage, contentTransition: .replace)
            volumeIcon.contentTintColor = .white
        } else {
            // 中间状态：直接显示 speaker.wave.3.fill，无额外动画
            let image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
            volumeIcon.image = image
            volumeIcon.contentTintColor = .white
        }
    }

    // MARK: - 音量图标点击事件：静音/恢复
    @objc private func volumeIconClicked() {
        if viewModel.volume > 0 {
            viewModel.volume = 0
        } else {
            viewModel.volume = viewModel.lastNonZero > 0 ? viewModel.lastNonZero : 1.0
        }
    }

    // MARK: - 鼠标事件与背景自动隐藏逻辑
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = containerTrackingArea { removeTrackingArea(area) }
        if let area = backgroundTrackingArea { controlsBackgroundView.removeTrackingArea(area) }

        containerTrackingArea = NSTrackingArea(rect: bounds,
                                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                               owner: self,
                                               userInfo: nil)
        addTrackingArea(containerTrackingArea!)

        backgroundTrackingArea = NSTrackingArea(rect: controlsBackgroundView.bounds,
                                                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                                owner: self,
                                                userInfo: nil)
        controlsBackgroundView.addTrackingArea(backgroundTrackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        let locationInSelf = convert(event.locationInWindow, from: nil)
        let locationInBackground = controlsBackgroundView.convert(locationInSelf, from: self)
        if controlsBackgroundView.bounds.contains(locationInBackground) {
            setBackgroundState(.locked)
        } else {
            if backgroundState == .hidden || backgroundState == .locked {
                setBackgroundState(.transient)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        let locationInSelf = convert(event.locationInWindow, from: nil)
        let locationInBackground = controlsBackgroundView.convert(locationInSelf, from: self)
        if !bounds.contains(locationInSelf) {
            setBackgroundState(.hidden)
            return
        }
        if !controlsBackgroundView.bounds.contains(locationInBackground) {
            if backgroundState == .locked {
                setBackgroundState(.transient)
            }
        }
    }

    private func setBackgroundState(_ newState: BackgroundState) {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        let oldState = backgroundState
        backgroundState = newState

        switch (oldState, newState) {
        case (_, .hidden):
            animateHideBackground()
        case (.hidden, .transient):
            animateShowBackground()
            startAutoHideTimer()
        case (.locked, .transient), (.transient, .transient):
            startAutoHideTimer()
        case (_, .locked):
            if oldState == .hidden { animateShowBackground() }
        default:
            break
        }
    }

    private func animateShowBackground() {
        let duration: CFTimeInterval = 0.3
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            controlsBackgroundView.animator().alphaValue = 1.0
            let fromTransform = CATransform3DMakeScale(0.95, 0.95, 1.0)
            let toTransform = CATransform3DIdentity
            controlsBackgroundView.layer?.animateTransform(from: fromTransform, to: toTransform, duration: duration)
        }
    }

    private func animateHideBackground() {
        let duration: CFTimeInterval = 0.3
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            controlsBackgroundView.animator().alphaValue = 0.0
            let toTransform = CATransform3DMakeScale(0.95, 0.95, 1.0)
            let currentTransform = controlsBackgroundView.layer?.transform ?? CATransform3DIdentity
            controlsBackgroundView.layer?.animateTransform(from: currentTransform, to: toTransform, duration: duration)
        }
    }

    private func startAutoHideTimer() {
        autoHideTimer = Timer.scheduledTimer(timeInterval: autoHideDelay, target: self, selector: #selector(autoHideTimerFired), userInfo: nil, repeats: false)
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
    }

    @objc private func togglePip() {
        viewModel.togglePipMode()
    }

    @objc private func volumeChanged() {
        viewModel.volume = Float(volumeSlider.doubleValue)
    }

    // 为了使播放器图层始终覆盖整个区域
    func updatePlayerLayer() {
        playerLayer?.removeFromSuperlayer()
        self.playerLayer = viewModel.playerLayer
        if let playerLayer = playerLayer {
            layer?.insertSublayer(playerLayer, at: 0)
            playerLayer.frame = self.bounds
        }
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = self.bounds
    }
}

// MARK: - CALayer 动画扩展（保持原有封装）
extension CALayer {
    func animateTransform(from: CATransform3D, to: CATransform3D, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
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
        return PlayerContainerView(frame: .zero, viewModel: viewModel)
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let containerView = nsView as? PlayerContainerView {
            containerView.updatePlayerLayer()
        }
    }
}

// MARK: - SwiftUI 内容视图
struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @State var m3u8Link: String = "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8"

    var body: some View {
        VStack {
            CustomPlayerView(viewModel: viewModel)
                .frame(width: 640, height: 360)

            TextField("请输入视频 URL", text: $m3u8Link)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding([.leading, .trailing])

            HStack {
                Button("切换视频源") {
                    viewModel.switchVideoSource(to: m3u8Link)
                }
                Button("切换播放器标题") {
                    viewModel.videoTitle = "新的直播间标题"
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
