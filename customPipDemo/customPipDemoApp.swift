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
    
    // 音量属性的封装：通过 getter/setter 统一读写 UserDefaults
    @Published var volume: Float {
        didSet {
            player.volume = volume
            saveVolume(volume)
        }
    }
    
    // 新增：可外部修改的标题
    @Published var videoTitle: String = "默认标题"
    
    static var shared = PlayerViewModel()
    
    private var playerTimeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        // 封装读取音量值
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
    
    // MARK: - 封装 UserDefaults 读写
    private static func loadVolume() -> Float? {
        return UserDefaults.standard.object(forKey: "playerVolume") as? Float
    }
    private func saveVolume(_ volume: Float) {
        UserDefaults.standard.set(volume, forKey: "playerVolume")
    }
    
    // MARK: - 添加周期性时间观察者（优化：使用defer确保移除旧观察者）
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
    
    // MARK: - 初始化播放器图层与 PiP 控制器
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
                // 优化：不使用固定延时，而是检测是否有有效的 seekableTimeRanges
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
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        pipState = .normal
        completionHandler(true)
    }
    
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
    
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        pipState = .normal
        playerState = .error(error)
    }
    
    // MARK: - 视频源切换（优化：保证切换过程的资源清理与错误处理）
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
        
        // 创建新播放器及相关组件
        player = AVPlayer(url: url)
        player.volume = volume
        setupTimeObserver()
        setupPlayerLayer()
        pipState = .normal
        
        // 优化：使用延迟判断 seekableTimeRanges 是否有效
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
    
    // MARK: - 资源清理（优化：使用 defer 保证清理完整）
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
    
    private var controlsBackgroundView: NSVisualEffectView!
    private var titleLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var volumeIcon: NSImageView!
    private var volumeSlider: NSSlider!
    private var playPauseButton: NSButton!
    private var pipButton: NSButton!
    
    private var containerTrackingArea: NSTrackingArea?
    private var backgroundTrackingArea: NSTrackingArea?
    
    private var backgroundState: BackgroundState = .hidden
    private var autoHideTimer: Timer?
    
    // 自动隐藏延时封装
    private var autoHideDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(autoHideDelay, forKey: "AutoHideDelayKey")
        }
    }
    
    // 常量配置
    private let buttonSize: CGFloat = 44
    private let buttonSpacing: CGFloat = 12
    private let controlsBackgroundCornerRadius: CGFloat = 12
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - 初始化（优化：将 UserDefaults 读取封装）
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
        bindViewModel()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - 绑定 ViewModel 状态（优化：封装订阅）
    private func bindViewModel() {
        viewModel.$playerState
            .sink { [weak self] state in
                self?.updateStatusLabel(for: state)
                self?.updatePlayPauseButtonImage()
            }
            .store(in: &cancellables)
        
        viewModel.$volume
            .sink { [weak self] newVolume in
                self?.updateVolumeIcon(for: newVolume)
            }
            .store(in: &cancellables)
        
        viewModel.$videoTitle
            .sink { [weak self] newTitle in
                self?.titleLabel.stringValue = newTitle
            }
            .store(in: &cancellables)
        
        viewModel.$pipState
            .sink { [weak self] _ in
                self?.updatePipButtonImage()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 播放器图层设置
    private func setupPlayerLayer() {
        if layer == nil { wantsLayer = true }
        self.playerLayer = viewModel.playerLayer
    }
    
    // MARK: - 控件背景设置（优化：提取函数便于后续迁移到 Auto Layout）
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
        addSubview(controlsBackgroundView)
    }
    
    // MARK: - 控件设置
    private func setupControls() {
        titleLabel = NSTextField(labelWithString: viewModel.videoTitle)
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        controlsBackgroundView.addSubview(titleLabel)
        
        statusLabel = NSTextField(labelWithString: "未开始播放")
        statusLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        controlsBackgroundView.addSubview(statusLabel)
        
        volumeIcon = NSImageView()
        volumeIcon.imageScaling = .scaleProportionallyUpOrDown
        controlsBackgroundView.addSubview(volumeIcon)
        
        volumeSlider = NSSlider(value: Double(viewModel.volume),
                                minValue: 0.0,
                                maxValue: 1.0,
                                target: self,
                                action: #selector(volumeChanged))
        controlsBackgroundView.addSubview(volumeSlider)
        
        playPauseButton = NSButton(title: "", target: self, action: #selector(togglePlayPause))
        playPauseButton.isBordered = false
        playPauseButton.imageScaling = .scaleProportionallyUpOrDown
        updatePlayPauseButtonImage()
        controlsBackgroundView.addSubview(playPauseButton)
        
        pipButton = NSButton(title: "", target: self, action: #selector(togglePip))
        pipButton.isBordered = false
        pipButton.imageScaling = .scaleProportionallyUpOrDown
        updatePipButtonImage()
        controlsBackgroundView.addSubview(pipButton)
    }
    
    // MARK: - 更新 UI 方法
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
    }
    
    private func updateVolumeIcon(for volume: Float) {
        let clampedVolume = max(0, min(volume, 1))
        if #available(macOS 13.0, *) {
            volumeIcon.image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                                       variableValue: Double(clampedVolume),
                                       accessibilityDescription: nil)
        } else {
            volumeIcon.image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                                       accessibilityDescription: nil)
        }
        volumeIcon.contentTintColor = .white
    }
    
    // MARK: - 布局（优化：封装布局代码便于后续切换到自动布局）
    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
        
        let backgroundWidth: CGFloat = 420
        let backgroundHeight: CGFloat = 110
        let backgroundX = (bounds.width - backgroundWidth) / 2
        let backgroundY: CGFloat = 20
        controlsBackgroundView.frame = NSRect(x: backgroundX, y: backgroundY, width: backgroundWidth, height: backgroundHeight)
        
        if let layer = controlsBackgroundView.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: controlsBackgroundView.frame.midX, y: controlsBackgroundView.frame.midY)
        }
        
        let margin: CGFloat = 8
        let labelHeight: CGFloat = 20
        let titleY = backgroundHeight - margin - labelHeight
        titleLabel.frame = NSRect(x: 0, y: titleY, width: backgroundWidth, height: labelHeight)
        let statusY = titleY - labelHeight - 4
        statusLabel.frame = NSRect(x: 0, y: statusY, width: backgroundWidth, height: labelHeight)
        
        let controlsY = statusY - buttonSize - 8
        var currentX = margin
        volumeIcon.frame = NSRect(x: currentX, y: controlsY, width: buttonSize, height: buttonSize)
        currentX += (buttonSize + buttonSpacing)
        let sliderWidth: CGFloat = 100
        volumeSlider.frame = NSRect(x: currentX, y: controlsY, width: sliderWidth, height: buttonSize)
        currentX += (sliderWidth + buttonSpacing)
        playPauseButton.frame = NSRect(x: currentX, y: controlsY, width: buttonSize, height: buttonSize)
        currentX += (buttonSize + buttonSpacing)
        pipButton.frame = NSRect(x: currentX, y: controlsY, width: buttonSize, height: buttonSize)
    }
    
    // MARK: - 更新追踪区域
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
    
    // MARK: - 鼠标事件与背景状态管理
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
            let fromTransform = CATransform3DMakeScale(0.8, 0.8, 1.0)
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
            let toTransform = CATransform3DMakeScale(0.8, 0.8, 1.0)
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
    
    func updatePlayerLayer() {
        playerLayer?.removeFromSuperlayer()
        self.playerLayer = viewModel.playerLayer
        if let playerLayer = playerLayer {
            layer?.insertSublayer(playerLayer, at: 0)
            playerLayer.frame = bounds
        }
    }
}

// MARK: - CALayer 动画扩展（优化：封装动画调用）
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
