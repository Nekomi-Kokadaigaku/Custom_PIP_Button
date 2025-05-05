//
//  ContentView.swift
//  customPipDemo
//

import SwiftUI


class ContentViewModel: ObservableObject {
    
    static let shared = ContentViewModel()
    
    @Published var streamTitle: String = ""
    @Published var m3u8Link: String = "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8"
}

struct ContentView: View {

    @StateObject var model = ContentViewModel.shared
    @StateObject var viewModel = PlayerViewModel.shared

    var body: some View {
        VStack {
            BiriPlayer()
                .frame(width: 800, height: 450)

            TextField("请输入视频 URL", text: $model.m3u8Link)
                .onSubmit {
                    viewModel.switchVideoSource(to: model.m3u8Link)
                    viewModel.videoTitle = model.streamTitle
                }
                .padding(.horizontal)
            
            TextField("输入标题", text: $model.streamTitle)
                .padding(.horizontal)
            
            Button("切换视频源") {
                viewModel.switchVideoSource(to: model.m3u8Link)
                viewModel.videoTitle = model.streamTitle
            }
        }
        .textFieldStyle(RoundedBorderTextFieldStyle())
    }
}


#Preview {
    ContentView()
}
