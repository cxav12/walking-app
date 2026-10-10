import SwiftUI

@main
struct WalkingWatch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(StepsAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
