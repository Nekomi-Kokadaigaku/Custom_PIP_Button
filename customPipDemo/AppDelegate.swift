//
//  AppDelegate.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-17.
//

import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApplication.shared.windows.first {
            window.isMovableByWindowBackground = true
        }
    }
}
