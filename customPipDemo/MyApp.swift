//
//  MyApp.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-27.
//

import SwiftUI


// MARK: - Usage
@main
struct MyApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
