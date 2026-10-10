import SwiftUI

@main
struct WalkingAppApp: App {
    @UIApplicationDelegateAdaptor(StepsAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
