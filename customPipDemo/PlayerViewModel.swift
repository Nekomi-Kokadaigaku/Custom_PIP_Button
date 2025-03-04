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
    
    @Published var player: AVPlayer!
    @Published var playerLayer: AVPlayerLayer!
    @Published var pipController: AVPictureInPictureController!
    
    // 音量属性，通过 getter/setter 统一读写 UserDefaults
    @Published var volume: Float {
        didSet {
            player.volume = volume
            saveVolume(volume)
        }
    }
    
    // 调试或 UI 使用的其它属性
    @Published var tKnobPosition: CGFloat = 0
    @Published var videoTitle: String = ""
    
    static var shared = PlayerViewModel()
    
    private var playerTimeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        self.volume = PlayerViewModel.loadVolume() ?? 1.0
        super.init()
        
        // 初始化播放器（默认 URL 流）
        let url = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player.volume = volume
        
        // 设置直播相关属性
        if let item = player.currentItem, #available(macOS 11.0, *) {
            item.automaticallyPreservesTimeOffsetFromLive = true
        }
        player.automaticallyWaitsToMinimizeStalling = false
        
        setupTimeObserver()
        setupPlayerLayer()
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
        updateNowPlayingInfo()
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
        updateNowPlayingInfo()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self,
                  let currentItem = self.player.currentItem,
                  let timeRange = currentItem.seekableTimeRanges.last?.timeRangeValue else {
                self?.player.play()
                self?.playerState = .playing
                self?.updateNowPlayingInfo()
                return
            }
            let livePosition = CMTimeAdd(timeRange.start, timeRange.duration)
            self.player.seek(to: livePosition, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                self.player.play()
                self.playerState = .playing
                self.updateNowPlayingInfo()
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
    
    private func updateNowPlayingInfo() {
        print("update now playing info")
        var infoCenter = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        infoCenter[MPMediaItemPropertyTitle] = videoTitle.isEmpty ? "123" : videoTitle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = infoCenter
    }
}
