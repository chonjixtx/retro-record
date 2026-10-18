import SwiftUI

@main
@MainActor
struct RetroRecordApp: App {
    @StateObject private var model = RecorderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
