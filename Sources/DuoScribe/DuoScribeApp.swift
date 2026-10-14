import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DuoScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DuoScribe") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    model.loadModel()
                }
        }
        .defaultSize(width: 1000, height: 640)
    }
}
