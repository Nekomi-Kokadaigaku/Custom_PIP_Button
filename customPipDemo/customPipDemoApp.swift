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

// MARK: - 自定义播放器视图
struct CustomPlayerView: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.layer = viewModel.playerLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer = viewModel.playerLayer
    }
}

// MARK: - 内容视图
struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()

    @State var m3u8Link: String = "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8"

    var body: some View {
        VStack {
            CustomPlayerView(viewModel: viewModel)
                .frame(width: 640, height: 360)

            // 添加占位符提示用户输入视频链接
            TextField("请输入视频 URL", text: $m3u8Link)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding([.leading, .trailing])
            
            // 自定义按钮区域：播放/暂停、画中画、以及音量调节
            HStack(spacing: 20) {
                Button(action: {
                    if viewModel.playerState.isPlaying {
                        viewModel.pause()
                    } else {
                        viewModel.play()
                    }
                }) {
                    Text(viewModel.playerState.isPlaying ? "暂停" : "播放")
                }
                Button(action: {
                    viewModel.togglePipMode()
                }) {
                    Text(viewModel.pipState == .active ? "退出画中画" : "进入画中画")
                }
                VStack {
                    Text("音量: \(Int(viewModel.volume * 100))%")
                    Slider(value: $viewModel.volume, in: 0.0...1.0)
                        .frame(width: 150)
                }
                Button(action: {
                    viewModel.switchVideoSource(to: m3u8Link)
                }) {
                    Text("切换视频源")
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
