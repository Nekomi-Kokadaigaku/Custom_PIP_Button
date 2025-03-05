//
//  CALayer+Animation.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-16.
//

import QuartzCore

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
extension CALayer {
    /// 修改 anchorPoint，但保证视图在父层中的可见位置保持不变
    func setAnchorPointWithoutMoving(_ newAnchorPoint: CGPoint) {
        guard let superlayer = superlayer else { return }

        // 计算旧的、和新的 anchorPoint 在父层坐标系中的位置
        let oldPoint = superlayer.convert(position, from: self)
        anchorPoint = newAnchorPoint
        let newPoint = superlayer.convert(position, from: self)

        // 调整 position，使得 layer 看起来没有发生位移
        position.x -= (newPoint.x - oldPoint.x)
        position.y -= (newPoint.y - oldPoint.y)
    }
}
