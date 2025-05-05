//
//  MyApp.swift
//  customPipDemo
//

import SwiftUI

@main
struct MyApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
