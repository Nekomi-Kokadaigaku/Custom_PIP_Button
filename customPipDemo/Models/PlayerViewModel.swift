//
//  PlayerViewModel.swift
//  customPipDemo
//

import AVKit
import Combine
import MediaPlayer
import SwiftUI

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

// MARK: - 视频播放 ViewModel
class PlayerViewModel: NSObject, ObservableObject  {

    @Published var outterRect: CGRect?

    @Published private(set) var playerState: PlayerState = .idle
    @Published private(set) var pipState: PiPState = .normal

    @Published private(set) var player: AVPlayer!
    @Published private(set) var playerLayer: AVPlayerLayer!
    @Published private(set) var pipController: AVPictureInPictureController?

    @AppStorage("playerVolume") var volumePlayer: Double = 0.5
    //    var volume: Float {
    //        set {
    //            defaults.set(newValue, forKey: "playerVolume")
    //        }
    //        get {
    //            defaults.object(forKey: "playerVolume") as? Float ?? 0
    //        }
    //    }

    @Published var videoTitle: String = ""

    static var shared = PlayerViewModel()

    private var playerTimeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    // 检查画中画是否可用
    var isPipSupported: Bool {
        return AVPictureInPictureController.isPictureInPictureSupported()
    }

    // 自动隐藏延时
    var autoHideDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(autoHideDelay, forKey: "AutoHideDelayKey")
        }
    }

    // 常量配置
    let buttonSize: CGFloat = 32
    let controlsBackgroundCornerRadius: CGFloat = 12

    let defaults = UserDefaults.standard

    // 检查播放器是否处于错误状态
    private var playerHasErrors: Bool {
        if case .error = playerState {
            return true
        }

        // 检查播放器项是否有错误
        if let currentItem = player.currentItem,
           currentItem.status == .failed ||
            currentItem.error != nil {
            return true
        }

        // 检查播放器本身是否有错误
        if player.status == .failed {
            return true
        }

        return false
    }

    override init() {
        self.autoHideDelay = defaults.object(forKey: "AutoHideDelayKey") as? TimeInterval ?? 3.0
        super.init()

        setupPlayer(Const.testURL)
        setupTimeObserver()
        setupPlayerLayer()
    }

    deinit {
        cleanupResources()
    }
}


extension PlayerViewModel {

    func setPlayerVolume(v: Double) {
        self.player.volume = Float(v)
    }

    private func setupPlayer(_ url: URL) {
        let asset = AVAsset(url: url)
        // 异步加载视频轨道信息
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError? = nil
            let status = asset.statusOfValue(forKey: "tracks", error: &error)
            if status == .loaded {
                DispatchQueue.main.async {
                    let playerItem = AVPlayerItem(asset: asset)

                    // 1. 获取视频轨道信息
                    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                        print("未获取到视频轨道")
                        return
                    }
                    // 2. 创建 AVMutableVideoComposition
                    let videoComposition = AVMutableVideoComposition()
                    videoComposition.renderSize = videoTrack.naturalSize
                    // 例如设置为 30 fps
                    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

                    // 创建视频合成指令，覆盖整个视频时长
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

                    // 图层指令（可以在此处添加额外的变换）
                    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                    instruction.layerInstructions = [layerInstruction]
                    videoComposition.instructions = [instruction]

                    // 3. 创建 Core Animation 图层，并添加文本层
                    let videoSize = videoTrack.naturalSize
                    // 父容器层，尺寸与视频一致
                    let parentLayer = CALayer()
                    parentLayer.frame = CGRect(origin: .zero, size: videoSize)

                    // 视频图层
                    let videoLayer = CALayer()
                    videoLayer.frame = CGRect(origin: .zero, size: videoSize)
                    parentLayer.addSublayer(videoLayer)

                    // 创建文本图层
                    let textLayer = CATextLayer()
                    textLayer.string = "这里是一行文字"
                    textLayer.font = CGFont("Helvetica-Bold" as CFString)
                    textLayer.fontSize = 36
                    textLayer.alignmentMode = .center
                    textLayer.foregroundColor = NSColor.white.cgColor
                    // 设置文本层位置，例如距离底部20像素，高度50像素
                    let textHeight: CGFloat = 50
                    textLayer.frame = CGRect(x: 0, y: 20, width: videoSize.width, height: textHeight)
                    // 保证在 Retina 显示下显示清晰
                    textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
                    parentLayer.addSublayer(textLayer)

                    // 使用 AVVideoCompositionCoreAnimationTool 绑定图层
                    videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)

                    // 4. 将视频合成对象绑定到 AVPlayerItem 上
                    playerItem.videoComposition = videoComposition

                    // 5. 创建 AVPlayer 并显示
                    self.player = AVPlayer(playerItem: playerItem)
                    self.playerLayer = AVPlayerLayer(player: self.player)
                    if let a = self.outterRect {
                        print(self.playerLayer.frame)
                        self.playerLayer?.frame = a
                    }

                    // 设置视图的 layer
//                    self.view.wantsLayer = true
//                    self.view.layer = CALayer()
//                    if let playerLayer = self.playerLayer {
//                        self.view.layer?.addSublayer(playerLayer)
//                    }
                }
            } else {
                print("加载轨道失败: \(error?.localizedDescription ?? "未知错误")")
            }
        }
        let playerItem = AVPlayerItem(url: url)
        playerItem.automaticallyPreservesTimeOffsetFromLive = true
        player = AVPlayer(playerItem: playerItem)
        player.volume = Float(self.volumePlayer)
        player.automaticallyWaitsToMinimizeStalling = false
    }
    func setOutterFrame(_ a: CGRect) {
        DispatchQueue.main.async {
            self.outterRect = a
        }
    }

    // MARK: - UserDefaults 操作
    private static func loadVolume() -> Float? {
        return UserDefaults.standard.object(forKey: "playerVolume") as? Float
    }
    private func saveVolume(_ volume: Float) {
        UserDefaults.standard.set(volume, forKey: "playerVolume")
    }

    // MARK: - 时间观察者
    private func setupTimeObserver() {
        if let observer = playerTimeObserver {
            player.removeTimeObserver(observer)
            playerTimeObserver = nil
        }
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        playerTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.updatePlayingStatus()
        }
    }

    // MARK: - 初始化播放器图层与 PiP 控制器
    private func setupPlayerLayer() {
        playerLayer = AVPlayerLayer(player: player)
        if isPipSupported {
            pipController = AVPictureInPictureController(playerLayer: playerLayer)
            pipController?.delegate = self
        }
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
            if let currentItem = player.currentItem,
               currentItem.duration.isIndefinite,
               let timeRange = currentItem.seekableTimeRanges.last?.timeRangeValue {
                let livePosition = CMTimeAdd(timeRange.start, timeRange.duration)
                player.seek(to: livePosition, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.player.play()
                    self?.playerState = .playing
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
        guard let pipController = pipController, AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }

        if pipState == .entering || pipState == .exiting { return }

        if pipState == .normal {
            pipState = .entering
            pipController.startPictureInPicture()
        } else if pipState == .active {
            pipState = .exiting
            pipController.stopPictureInPicture()
            if let mainWindow = NSApplication.shared.windows.first {
                mainWindow.makeKeyAndOrderFront(nil)
            }
        }
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
            pipController?.stopPictureInPicture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.performVideoSourceSwitch(url: url)
            }
        } else {
            performVideoSourceSwitch(url: url)
        }
    }

    private func performVideoSourceSwitch(url: URL) {
        // 检查播放器状态，决定是否需要创建新实例
        let needsNewPlayer = (player == nil || playerHasErrors)

        if needsNewPlayer {
            // 如果需要，创建新的播放器
            print("create new player")
            cleanupResources()
            player = AVPlayer(url: url)
            setupTimeObserver()
            setupPlayerLayer()
        } else {
            // 否则，只替换媒体项
            debugPrint("replace current item")
            let playerItem = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: playerItem)
        }

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
            self.player.seek(to: livePosition, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                self.player.play()
                self.playerState = .playing
            }
        }
    }

    // MARK: - 资源清理
    private func cleanupResources() {
        // 先暂停播放
        player.pause()

        // 移除时间观察者
        if let observer = playerTimeObserver {
            player.removeTimeObserver(observer)
            playerTimeObserver = nil
        }

        // 停止画中画
        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        pipController = nil

        // 清理播放器图层
        playerLayer = nil

        // 最后清理播放器项
        player.replaceCurrentItem(with: nil)
    }


}


extension PlayerViewModel: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        pipState = .active
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        pipState = .normal
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        pipState = .normal
        playerState = .error(error)
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        pipState = .normal
        completionHandler(true)
    }
}
