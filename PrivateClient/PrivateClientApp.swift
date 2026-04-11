import SwiftUI
import Partout

@main
struct PrivateClientApp: App {
    @State
    private var model = AppModel()

    private let tunnel = TunnelObservable.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, tunnel: tunnel)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Regions") {
                    Task { await model.refreshRegions() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isAuthenticated || model.isBusy)
            }

            CommandGroup(after: .toolbar) {
                Divider()
                Menu {
                    Toggle(
                        "By Latency",
                        isOn: Binding(
                            get: { model.sidebarSortMode == .latency },
                            set: { isEnabled in
                                if isEnabled {
                                    model.sidebarSortMode = .latency
                                }
                            }
                        )
                    )

                    Toggle(
                        "Alphabetically",
                        isOn: Binding(
                            get: { model.sidebarSortMode == .alphabetical },
                            set: { isEnabled in
                                if isEnabled {
                                    model.sidebarSortMode = .alphabetical
                                }
                            }
                        )
                    )
                }
                label: {
                    Label("Sort Servers", systemImage: "arrow.up.arrow.down")
                }
            }
        }
    }
}
