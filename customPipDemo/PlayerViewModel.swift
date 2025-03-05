//
//  PlayerViewModel.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-16.
//  修改日期: 2025-03-01
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
class PlayerViewModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var playerState: PlayerState = .idle
    @Published private(set) var pipState: PiPState = .normal

    @Published private(set) var player: AVPlayer!
    @Published private(set) var playerLayer: AVPlayerLayer!
    @Published private(set) var pipController: AVPictureInPictureController?

    // 音量属性，通过 getter/setter 统一读写 UserDefaults
    @Published var volume: Float {
        didSet {
            player.volume = volume
            ud.set(volume, forKey: "playerVolume")
        }
    }
//    var volume: Float {
//        set {
//            ud.set(newValue, forKey: "playerVolume")
//        }
//        get {
//            ud.object(forKey: "playerVolume") as? Float ?? 0
//        }
//    }

    @Published var videoTitle: String = ""

    static var shared = PlayerViewModel()

    static var `deafult` = PlayerViewModel()

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

    let ud = UserDefaults.standard
    // 初始化播放器（默认 URL 流）
    static let testURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!

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
        self.autoHideDelay = ud.object(forKey: "AutoHideDelayKey") as? TimeInterval ?? 3.0
        self.volume = PlayerViewModel.loadVolume() ?? 0
        super.init()
        print(volume)


        setupPlayer(PlayerViewModel.testURL)
        setupTimeObserver()
        setupPlayerLayer()
    }

    // MARK: - Setup AVPlayer
    private func setupPlayer(_ url: URL) {
        let playerItem = AVPlayerItem(url: url)
        playerItem.automaticallyPreservesTimeOffsetFromLive = true
        player = AVPlayer(playerItem: playerItem)
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = false
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
            player.volume = volume
            setupTimeObserver()
            setupPlayerLayer()
        } else {
            // 否则，只替换媒体项
            print("replace current item")
            let playerItem = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: playerItem)
        }
        pipState = .normal
        NowPlayingCenter.updateNowPlayingInfo()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self,
                  let currentItem = self.player.currentItem,
                  let timeRange = currentItem.seekableTimeRanges.last?.timeRangeValue else {
                self?.player.play()
                self?.playerState = .playing
                NowPlayingCenter.updateNowPlayingInfo()
                return
            }
            let livePosition = CMTimeAdd(timeRange.start, timeRange.duration)
            self.player.seek(to: livePosition, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                self.player.play()
                self.playerState = .playing
                NowPlayingCenter.updateNowPlayingInfo()
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

    deinit {
        cleanupResources()
    }
}
