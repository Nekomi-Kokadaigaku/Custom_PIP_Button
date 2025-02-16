//
//  customPipDemoApp.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-16.
//

import SwiftUI
import AVKit

// MARK: - Usage
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

import SwiftUI
import AVFoundation
import AVKit

struct CustomPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let playerLayer: AVPlayerLayer
    let pipController: AVPictureInPictureController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
//        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = view.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = playerLayer
        view.wantsLayer = true
        player.play()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 更新视图
    }
}

struct ContentView: View {
    let player = AVPlayer(url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!)
    let playerlayer: AVPlayerLayer
    let pipController: AVPictureInPictureController

    init() {
        pipController = AVPictureInPictureController(playerLayer: AVPlayerLayer(player: player))!
        playerlayer = AVPlayerLayer(player: player)
    }

    var body: some View {
        VStack {
            CustomPlayerView(player: player, playerLayer: playerlayer, pipController: pipController)
                .frame(width: 640, height: 360)
            Button(action: {
                if pipController.isPictureInPictureActive {
                    pipController.stopPictureInPicture()
                } else {
                    pipController.startPictureInPicture()
                }
            }) {
                Text(pipController.isPictureInPictureActive ? "退出画中画" : "进入画中画")
            }
        }
    }
}


//// MARK: - Main Player View
//struct ContentView: View {
//    @StateObject private var viewModel = PlayerViewModel()
//    
//    var body: some View {
//        VStack {
//            VideoPlayerView(player: viewModel.player)
//                .frame(height: 300)
//                .background(Color.black)
//            
//            CustomControlsView(viewModel: viewModel)
//        }
//        .padding()
//        .onAppear {
//            viewModel.setupPIPController()
//            viewModel.loadVideo()
//        }
//    }
//}
//
//// MARK: - ViewModel
//class PlayerViewModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
//    @Published var isPlaying = false
//    @Published var progress: Double = 0
//    @Published var isPiPActive = false
//    @Published var isPiPAvailable = false
//    
//    let player = AVPlayer()
//    private var pipController: AVPictureInPictureController?
//    private var timeObserver: Any?
//    
//    override init() {
//        super.init()
//        setupTimeObserver()
//    }
//    
//    func loadVideo() {
//        guard let url = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8") else { return }
//        let playerItem = AVPlayerItem(url: url)
//        player.replaceCurrentItem(with: playerItem)
//        player.play()
//    }
//    
//    func setupPIPController() {
//        guard let playerLayer = (player.currentItem?.asset).flatMap({ _ in
//            AVPlayerLayer(player: player)
//        }) else { return }
//        
//        pipController = AVPictureInPictureController(playerLayer: playerLayer)
//        pipController?.delegate = self
//        isPiPAvailable = pipController?.isPictureInPicturePossible ?? false
////        isPiPAvailable = pipController?.isPictureInPicturePossible ?? false
//    }
//    
//    func togglePlayback() {
//        if player.rate == 0 {
//            player.play()
//        } else {
//            player.pause()
//        }
//        isPlaying = player.rate != 0
//    }
//    
//    func seekProgress(_ editing: Bool) {
//        guard let duration = player.currentItem?.duration.seconds, duration > 0 else { return }
//        let time = CMTime(seconds: duration * progress, preferredTimescale: 600)
//        player.seek(to: time)
//    }
//    
//    func togglePIP() {
//        guard let pipController = pipController else {
//            print("no pip controller")
//            return
//        }
//        
//        if pipController.isPictureInPictureActive {
//            pipController.stopPictureInPicture()
//        } else {
//            pipController.startPictureInPicture()
//        }
//    }
//    
//    private func setupTimeObserver() {
//        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
//        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
//            guard let self = self else { return }
//            self.updateProgress()
//        }
//    }
//    
//    private func updateProgress() {
//        guard let duration = player.currentItem?.duration.seconds,
//              duration.isFinite, duration > 0 else {
//            progress = 0
//            return
//        }
//        progress = player.currentTime().seconds / duration
//    }
//    
//    // MARK: - PiP Delegate
//    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
//        isPiPActive = true
//    }
//    
//    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
//        isPiPActive = false
//    }
//    
//    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
//        print("PiP failed to start: \(error.localizedDescription)")
//    }
//}
//// MARK: - Player View (NSViewRepresentable)
//struct VideoPlayerView: NSViewRepresentable {
//    let player: AVPlayer
//    
//    func makeNSView(context: Context) -> NSView {
//        let view = PlayerNSView()
//        view.player = player
//        return view
//    }
//    
//    func updateNSView(_ nsView: NSView, context: Context) {}
//}
//
//class PlayerNSView: NSView {
//    var player: AVPlayer? {
//        didSet {
//            guard let layer = layer as? AVPlayerLayer else { return }
//            layer.player = player
//            print("Avplayer is set.")
//        }
//    }
//    
//    override init(frame: CGRect) {
//        super.init(frame: frame)
//        setupLayer()
//    }
//    
//    required init?(coder: NSCoder) {
//        super.init(coder: coder)
//        setupLayer()
//    }
//    
//    private func setupLayer() {
//        self.wantsLayer = true
//        self.layer = AVPlayerLayer()
//    }
//    
//    override func layout() {
//        super.layout()
//        (layer as? AVPlayerLayer)?.frame = bounds
//    }
//}
//
//// MARK: - Custom Controls
//struct CustomControlsView: View {
//    @ObservedObject var viewModel: PlayerViewModel
//    
//    var body: some View {
//        HStack {
//            Button(action: {
//                viewModel.togglePlayback()
//            }) {
//                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
//                    .font(.title)
//            }
//            
//            Slider(value: $viewModel.progress, in: 0...1) { editing in
//                viewModel.seekProgress(editing)
//            }
//            .frame(width: 200)
//            
//            Button(action: {
//                viewModel.togglePIP()
//            }) {
//                Image(systemName: viewModel.isPiPActive ? "pip.exit" : "pip.enter")
//                    .font(.title)
//            }
////            .disabled(!viewModel.isPiPAvailable)
//        }
//        .padding()
//    }
//}
