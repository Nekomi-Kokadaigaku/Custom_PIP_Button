//
//  customPipDemoApp.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-16.
//

import AVKit
import SwiftUI

// MARK: - Usage
@main
struct MyApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - 播放器状态定义
enum PlayerState {
    case idle
    case loading
    case playing
    case paused
    case error(Error)

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }
}

enum PiPState {
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

    static var shared = PlayerViewModel()

    private var playerTimeObserver: Any?

    override init() {
        super.init()

        // 初始化播放器
        let url = URL(
            string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        player = AVPlayer(url: url)

        setupTimeObserver()
        setupPlayerLayer()
    }

    private func setupTimeObserver() {
        let interval = CMTime(
            seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        playerTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) {
            [weak self] _ in
            self?.updatePlayingStatus()
        }
    }

    private func setupPlayerLayer() {
        playerLayer = AVPlayerLayer(player: player)
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController?.delegate = self
    }

    private func updatePlayingStatus() {
        playerState = .playing
    }

    func play() {
        guard case .paused = playerState else { return }
        player.play()
        playerState = .playing
    }

    func pause() {
        guard case .playing = playerState else { return }
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
            playerState = .error(NSError(domain: "Invalid URL", code: -1))
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

        pipController?.stopPictureInPicture()
        pipController = nil

        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - PiP Delegate Methods
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        pipState = .active
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        pipState = .normal
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
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
        // 更新视图层
        nsView.layer = viewModel.playerLayer
    }
}

// MARK: - 内容视图
struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()

    @State var m3u8Link: String =
        "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8"

    var body: some View {
        VStack {
            CustomPlayerView(viewModel: viewModel)
                .frame(width: 640, height: 360)

            TextField("", text: $m3u8Link)

            HStack {
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
