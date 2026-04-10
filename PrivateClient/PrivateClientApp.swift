import SwiftUI

@main
struct PrivateClientApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
    }
}
