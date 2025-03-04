//
//  CustomSliderCell.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-16.
//

import AppKit

// Thanks to [https://stackoverflow.com/questions/71337289/nsslider-custom-subclass-how-to-maintain-the-link-between-the-knob-position-an]
// MARK: - 自定义滑块单元
class SeekSliderCell: NSSliderCell {
    
    override var knobThickness: CGFloat {
        return knobWidth
    }
    
    let knobWidth: CGFloat = 3
    let knobHeight: CGFloat = 15
    let knobRadius: CGFloat = 1
    let barRadius: CGFloat = 1.5
    
    private var knobColor = NSColor(named: .mainSliderKnob)!
    private var knobActiveColor = NSColor(named: .mainSliderKnobActive)!
    private var barColorLeft = NSColor(named: .mainSliderBarLeft)!
    private var barColorRight = NSColor(named: .mainSliderBarRight)!
    
    var knobPositionUpdateHandler: ((NSRect, NSRect, NSRect) -> Void)?
    
    override func drawKnob(_ knobRect: NSRect) {
        _ = drawKnobOnly(knobRect: knobRect)
    }
    
    @discardableResult
    private func drawKnobOnly(knobRect: NSRect) -> NSBezierPath {
        let rect = NSMakeRect(round(knobRect.origin.x),
                              knobRect.origin.y + 0.5 * (knobRect.height - knobHeight),
                              knobRect.width,
                              knobHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: knobRadius, yRadius: knobRadius)
        (isHighlighted ? knobActiveColor : knobColor).setFill()
        path.fill()
        return path
    }
    
    override func knobRect(flipped: Bool) -> NSRect {
        guard let slider = self.controlView as? NSSlider else { return super.knobRect(flipped: flipped) }
        let barRect = self.barRect(flipped: flipped)
        let percentage = slider.doubleValue / (slider.maxValue - slider.minValue)
        let effectiveBarWidth = barRect.width - knobWidth
        let pos = barRect.origin.x + CGFloat(percentage) * effectiveBarWidth
        let rect = super.knobRect(flipped: flipped)
        let height: CGFloat
        if #available(macOS 11, *) {
            height = (barRect.origin.y - rect.origin.y) * 2 + barRect.height
        } else {
            height = rect.height
        }
        return NSMakeRect(pos, rect.origin.y, knobWidth, height)
    }
    
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let knobPos: CGFloat = round(knobRect(flipped: flipped).origin.x)
        let progress: CGFloat = knobPos
        
        NSGraphicsContext.saveGraphicsState()
        let barRect: NSRect
        if #available(macOS 11, *) {
            barRect = rect
        } else {
            barRect = NSMakeRect(rect.origin.x, rect.origin.y + 1, rect.width, rect.height - 2)
        }
        let path = NSBezierPath(roundedRect: barRect, xRadius: barRadius, yRadius: barRadius)
        
        let pathLeftRect: NSRect = NSMakeRect(barRect.origin.x, barRect.origin.y, progress, barRect.height)
        NSBezierPath(rect: pathLeftRect).addClip()
        
        path.append(NSBezierPath(rect: NSRect(x: knobPos - 1, y: barRect.origin.y, width: knobWidth + 2, height: barRect.height)).reversed)
        barColorLeft.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        
        NSGraphicsContext.saveGraphicsState()
        let pathRight = NSMakeRect(barRect.origin.x + progress, barRect.origin.y, barRect.width - progress, barRect.height)
        NSBezierPath(rect: pathRight).setClip()
        barColorRight.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        
        knobPositionUpdateHandler?(rect, knobRect(flipped: flipped), barRect)
    }
}

// MARK: - NSColor 扩展：滑块颜色定义
extension NSColor.Name {
    static let mainSliderKnob = NSColor.Name("MainSliderKnob")
    static let mainSliderKnobActive = NSColor.Name("MainSliderKnobActive")
    static let mainSliderBarLeft = NSColor.Name("MainSliderBarLeft")
    static let mainSliderBarRight = NSColor.Name("MainSliderBarRight")
}
