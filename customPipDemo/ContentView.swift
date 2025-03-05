//
//  ContentView.swift
//  customPipDemo
//
//  Created by Iris on 2025-02-27.
//

import SwiftUI

// MARK: - NSViewRepresentable 封装 PlayerContainerView
struct CustomPlayerView: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel
    func makeNSView(context: Context) -> NSView {
        print("make NSView")
        return PlayerContainerView(frame: .zero, viewModel: viewModel)
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        print("update NSView")
        if let containerView = nsView as? PlayerContainerView {
            containerView.updatePlayerLayer()
        }
    }
}

// MARK: - 主内容视图
struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @State var m3u8Link: String = "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8"
    
    var body: some View {
        VStack {
            CustomPlayerView(viewModel: viewModel)
                .frame(width: 800, height: 450)
            
            TextField("请输入视频 URL", text: $m3u8Link)
                .onSubmit {
                    viewModel.switchVideoSource(to: m3u8Link)
                    viewModel.videoTitle = "This new stream title."
                }
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding([.leading, .trailing])
            
            HStack {
                Button("切换视频源") {
                    viewModel.switchVideoSource(to: m3u8Link)
                    viewModel.videoTitle = "夜不能寐吗"
                }
                Button("切换播放器标题") {
                    viewModel.videoTitle = "新的直播间标题"
                }
            }
            .padding()
        }
    }
}

#if DEBUG
#Preview {
    ContentView()
}
#endif
