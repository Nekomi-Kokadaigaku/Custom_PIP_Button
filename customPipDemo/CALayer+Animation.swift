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
