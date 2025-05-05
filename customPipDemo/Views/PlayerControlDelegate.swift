import Foundation

protocol PlayerControlDelegate: AnyObject {
    // 状态管理
    func playerControlDidRequestBackgroundStateChange(_ state: BackgroundState)
    func playerControlDidAutoHideTimerFire()

    // 用户交互
    func playerControlDidTapPlayPause()
    func playerControlDidTapPip()
    func playerControlDidChangeVolume(to value: Float)

    // 状态通知
    func playerControlDidMouseEnter(isInBackground: Bool)
    func playerControlDidMouseExit(isInView: Bool, isInBackground: Bool)
}