//
//  AppDelegate.swift
//  customPipDemo
//

import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApplication.shared.windows.first {
            window.isMovableByWindowBackground = true
        }
    }
}
