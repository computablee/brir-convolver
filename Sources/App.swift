import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let path = i + 1 < args.count ? args[i + 1] : ""
            exit(SelfTest.run(wavPath: path) ? 0 : 1)
        }
        BRIRConvolverApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppState.shared
    }
    func applicationWillTerminate(_ notification: Notification) {
        // Tear down the tap so other apps are unmuted immediately.
        MainActor.assumeIsolated { AppState.shared.prepareForQuit() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct BRIRConvolverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        Window("BRIR Convolver", id: "main") {
            MainView()
        }
        .windowResizability(.contentSize)

        Window("BRIR Analysis", id: "viz") {
            VisualizerView()
        }
        .defaultSize(width: 1180, height: 780)

        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: state.running ? (state.bypass ? "headphones.circle" : "headphones.circle.fill") : "headphones")
        }
    }
}
