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

enum PiPState: Equatable {
    case normal
    case entering
    case active
    case exiting
}

// MARK: - 视图模型
class PlayerViewModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var playerState: PlayerState = .idle
    @Published private(set) var pipState: PiPState = .normal

    @Published var player: AVPlayer!
    @Published var playerLayer: AVPlayerLayer!
    @Published var pipController: AVPictureInPictureController!
    
    // 新增音量属性，持久化保存
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
// 该 view 包含播放器显示层和自定义的控制层，控制层包含播放/暂停、画中画和音量调节，且鼠标 hover 时显示，不 hover 时隐藏动画
class PlayerContainerView: NSView {
    var viewModel: PlayerViewModel
    var playerLayer: AVPlayerLayer? {
        didSet {
            // 移除旧的 layer，并添加新的
            oldValue?.removeFromSuperlayer()
            if let newLayer = playerLayer {
                self.layer?.insertSublayer(newLayer, at: 0)
                newLayer.frame = self.bounds
            }
        }
    }
    
    // 控制层视图
    var controlsView: NSView!
    var playPauseButton: NSButton!
    var pipButton: NSButton!
    var volumeSlider: NSSlider!
    
    // 跟踪区域
    var trackingArea: NSTrackingArea?
    
    init(frame frameRect: NSRect, viewModel: PlayerViewModel) {
        self.viewModel = viewModel
        super.init(frame: frameRect)
        self.wantsLayer = true
        // 初始化播放器层
        setupPlayerLayer()
        // 初始化控制层
        setupControls()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea {
            removeTrackingArea(ta)
        }
        trackingArea = NSTrackingArea(rect: self.bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
        addTrackingArea(trackingArea!)
    }
    
    override func layout() {
        super.layout()
        // 更新播放器 layer 的 frame
        playerLayer?.frame = self.bounds
        
        // 将控制层放置在底部
        let controlsHeight: CGFloat = 50
        controlsView.frame = NSRect(x: 0, y: 0, width: self.bounds.width, height: controlsHeight)
        
        // 内部控件布局：左右居中排列
        let buttonWidth: CGFloat = 80
        let sliderWidth: CGFloat = 150
        let spacing: CGFloat = 20
        let totalWidth = buttonWidth * 2 + sliderWidth + spacing * 2
        let startX = (controlsView.bounds.width - totalWidth) / 2
        playPauseButton.frame = NSRect(x: startX, y: (controlsView.bounds.height - 30) / 2, width: buttonWidth, height: 30)
        pipButton.frame = NSRect(x: startX + buttonWidth + spacing, y: (controlsView.bounds.height - 30) / 2, width: buttonWidth, height: 30)
        volumeSlider.frame = NSRect(x: startX + buttonWidth * 2 + spacing * 2, y: (controlsView.bounds.height - 30) / 2, width: sliderWidth, height: 30)
    }
    
    // 设置播放器 layer
    func setupPlayerLayer() {
        if self.layer == nil {
            self.wantsLayer = true
        }
        self.playerLayer = viewModel.playerLayer
    }
    
    // 设置控制层（播放/暂停、画中画、音量调节）
    func setupControls() {
        controlsView = NSView(frame: .zero)
        controlsView.wantsLayer = true
        controlsView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        controlsView.alphaValue = 0.0  // 初始隐藏
        addSubview(controlsView)
        
        // 播放/暂停按钮
        playPauseButton = NSButton(title: viewModel.playerState.isPlaying ? "暂停" : "播放",
                                   target: self,
                                   action: #selector(togglePlayPause))
        playPauseButton.bezelStyle = .automatic
        controlsView.addSubview(playPauseButton)
        
        // 画中画按钮
        pipButton = NSButton(title: viewModel.pipState == .active ? "退出画中画" : "进入画中画",
                             target: self,
                             action: #selector(togglePip))
        pipButton.bezelStyle = .rounded
        controlsView.addSubview(pipButton)
        
        // 音量滑块
        volumeSlider = NSSlider(value: Double(viewModel.volume), minValue: 0.0, maxValue: 1.0, target: self, action: #selector(volumeChanged))
        controlsView.addSubview(volumeSlider)
    }
    
    // 鼠标进入显示控制层动画
    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            controlsView.animator().alphaValue = 1.0
        }
    }
    
    // 鼠标离开隐藏控制层动画
    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            controlsView.animator().alphaValue = 0.0
        }
    }
    
    @objc func togglePlayPause() {
        if viewModel.playerState.isPlaying {
            viewModel.pause()
            playPauseButton.title = "播放"
        } else {
            viewModel.play()
            playPauseButton.title = "暂停"
        }
    }
    
    @objc func togglePip() {
        viewModel.togglePipMode()
        if viewModel.pipState == .active {
            pipButton.title = "退出画中画"
        } else {
            pipButton.title = "进入画中画"
        }
    }
    
    @objc func volumeChanged() {
        viewModel.volume = Float(volumeSlider.doubleValue)
    }
    
    // 在切换视频源后更新 playerLayer
    func updatePlayerLayer() {
        // 移除旧的播放器 layer 并添加新的
        playerLayer?.removeFromSuperlayer()
        self.playerLayer = viewModel.playerLayer
        if let playerLayer = playerLayer {
            self.layer?.insertSublayer(playerLayer, at: 0)
            playerLayer.frame = self.bounds
        }
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

// MARK: - 内容视图
struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()

    @State var m3u8Link: String = "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8"

    var body: some View {
        VStack {
            // 使用自定义播放器视图（含播放器和控制层）
            CustomPlayerView(viewModel: viewModel)
                .frame(width: 640, height: 360)
            
            // 输入视频 URL 与切换视频源按钮（保留在 SwiftUI 中）
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
