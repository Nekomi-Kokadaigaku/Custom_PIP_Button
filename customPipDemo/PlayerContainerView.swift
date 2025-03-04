//
//  PlayerContainerView.swift
//  customPipDemo
//
//  Created by Iris on 2025-03-04.
//

import AppKit
import SwiftUI
import Combine
import AVKit

// MARK: - 背景状态定义
enum BackgroundState {
    case hidden, transient, locked
}

// MARK: - 音量状态（原 aState 重命名）
enum VolumeTransitionState {
    case fromOne, fromZero, notZero
}

// MARK: - 自定义播放器容器视图
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

    // 显示播放状态或者标题
    private var infoLabel: NSTextField!
    // 调试用显示滑块信息
    private var debugInfoTextField: NSTextField!

    private var volumeIcon: NSImageView!
    private var volumeSlider: NSSlider!
    private var playPauseButton: NSButton!
    private var pipButton: NSButton!

    private var controlsBackgroundView: NSVisualEffectView!
    private var containerTrackingArea: NSTrackingArea?
    private var backgroundTrackingArea: NSTrackingArea?

    private var backgroundState: BackgroundState = .hidden
    private var autoHideTimer: Timer?
    private var previousVolumeState: VolumeTransitionState = .notZero

    // 自动隐藏延时
    private var autoHideDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(autoHideDelay, forKey: "AutoHideDelayKey")
        }
    }

    // 常量配置
    private let buttonSize: CGFloat = 32
    private let controlsBackgroundCornerRadius: CGFloat = 12

    private var cancellables = Set<AnyCancellable>()

    // 自定义滑块单元
    var seekSliderCell = SeekSliderCell()

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
        setupDebugInfoTextField()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupDebugInfoTextField() {
        debugInfoTextField = NSTextField(labelWithString: "Knob Position: ")
        debugInfoTextField.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        debugInfoTextField.textColor = .white
        debugInfoTextField.wantsLayer = true
        debugInfoTextField.layer?.cornerRadius = 4
        debugInfoTextField.layer?.masksToBounds = true
        debugInfoTextField.layer?.backgroundColor = NSColor.gray.cgColor
        debugInfoTextField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(debugInfoTextField)

        NSLayoutConstraint.activate([
            debugInfoTextField.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 20),
            debugInfoTextField.topAnchor.constraint(equalTo: self.topAnchor, constant: 20)
        ])
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
        controlsBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlsBackgroundView)
    }

    // MARK: - 初始化控件
    private func setupControls() {
        // infoLabel：同时显示标题或状态
        infoLabel = NSTextField(labelWithString: "未开始播放")
        infoLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        infoLabel.textColor = .white
        infoLabel.alignment = .center
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        controlsBackgroundView.addSubview(infoLabel)

        // 音量图标
        volumeIcon = NSImageView()
        volumeIcon.imageScaling = .scaleProportionallyDown
        volumeIcon.translatesAutoresizingMaskIntoConstraints = false
        controlsBackgroundView.addSubview(volumeIcon)

        // 音量滑块
        volumeSlider = NSSlider(value: Double(viewModel.volume),
                                minValue: 0.0,
                                maxValue: 1.0,
                                target: self,
                                action: #selector(volumeChanged))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.cell = SeekSliderCell()
        volumeSlider.cell?.target = self
        volumeSlider.cell?.action = #selector(volumeChanged)
        (volumeSlider.cell as? SeekSliderCell)?.knobPositionUpdateHandler = { [weak self] originRect, knobRect, barRect in
            self?.updateDebugInfo(originRect, knobRect, barRect)
        }
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
        pipButton.imageScaling = .scaleProportionallyDown
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        updatePipButtonImage()
        controlsBackgroundView.addSubview(pipButton)
    }

    private func updateDebugInfo(
        _ originRect: NSRect,
        _ knobRect: NSRect,
        _ barRect: NSRect
    ) {
        var info = "originRect.x: \(originRect.origin.x)"
        info += "\noriginRect.y: \(originRect.origin.y)"
        info += "\noriginRect.width: \(originRect.size.width)"
        info += "\noriginRect.height: \(originRect.size.height)"
        info += "\nKnobRect.x: \(round(knobRect.origin.x))"
        info += "\nKnobRect.y: \(knobRect.origin.y)"
        info += "\nKnobRect.width: \(knobRect.size.width)"
        info += "\nKnobRect.height: \(knobRect.size.height)"
        info += "\nbarRect.x: \(barRect.origin.x)"
        info += "\nbarRect.y: \(barRect.origin.y)"
        info += "\nbarRect.width: \(barRect.size.width)"
        info += "\nbarRect.height: \(barRect.size.height)"
        debugInfoTextField.stringValue = info
    }

    // MARK: - Auto Layout 约束
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
            playPauseButton.heightAnchor.constraint(equalToConstant: buttonSize)
        ])

        NSLayoutConstraint.activate([
            volumeIcon.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            volumeIcon.leadingAnchor.constraint(equalTo: controlsBackgroundView.leadingAnchor, constant: 16),
            volumeIcon.widthAnchor.constraint(equalToConstant: 32),
            volumeIcon.heightAnchor.constraint(equalToConstant: 32),

            volumeSlider.centerYAnchor.constraint(equalTo: volumeIcon.centerYAnchor),
            volumeSlider.leadingAnchor.constraint(equalTo: volumeIcon.trailingAnchor, constant: 8),
            volumeSlider.widthAnchor.constraint(equalToConstant: 100)
        ])

        NSLayoutConstraint.activate([
            pipButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            pipButton.trailingAnchor.constraint(equalTo: controlsBackgroundView.trailingAnchor, constant: -16),
            pipButton.widthAnchor.constraint(equalToConstant: 32),
            pipButton.heightAnchor.constraint(equalToConstant: 32)
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

    // MARK: - 更新 infoLabel 的显示逻辑
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

    private func updateVolumeIcon(for volume: Float) {
        let clampedVolume = max(0, min(volume, 1))
        if #available(macOS 13.0, *) {
            if clampedVolume == 1 {
                let image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                                    variableValue: Double(clampedVolume),
                                    accessibilityDescription: nil)
                volumeIcon.image = image
                volumeIcon.contentTintColor = .white
                volumeIcon.removeAllSymbolEffects()
                volumeIcon.addSymbolEffect(.bounce)
                volumeIcon.frame.size = NSSize(width: 25, height: 25)
                previousVolumeState = .fromOne
            } else if clampedVolume == 0 {
                let image = NSImage(systemSymbolName: "speaker.slash.fill",
                                    variableValue: Double(clampedVolume),
                                    accessibilityDescription: nil)!
                volumeIcon.contentTintColor = .white
                volumeIcon.removeAllSymbolEffects()
                volumeIcon.setSymbolImage(image, contentTransition: .replace.upUp)
                volumeIcon.frame.size = NSSize(width: 25, height: 25)
                previousVolumeState = .fromZero
            } else {
                let image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                                    variableValue: Double(clampedVolume),
                                    accessibilityDescription: nil)!
                volumeIcon.image = image
                volumeIcon.contentTintColor = .white
                volumeIcon.removeAllSymbolEffects()
                if previousVolumeState == .fromZero {
                    volumeIcon.setSymbolImage(image, contentTransition: .replace)
                }
                volumeIcon.frame.size = NSSize(width: 25, height: 25)
                previousVolumeState = .notZero
            }
        } else {
            volumeIcon.image = NSImage(systemSymbolName: "speaker.wave.3.fill",
                                       accessibilityDescription: nil)
            volumeIcon.contentTintColor = .white
        }
    }

    // MARK: - 鼠标事件与自动隐藏
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
    
    // MARK: - 音量图标点击事件：静音/恢复
    @objc private func volumeIconClicked() {
//        if viewModel.volume > 0 {
//            viewModel.volume = 0
//        } else {
//            viewModel.volume = viewModel.lastNonZero > 0 ? viewModel.lastNonZero : 1.0
//        }
    }

    // 外部调用以更新播放器图层
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
