import SwiftUI
import Partout
import AppKit

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

        MenuBarExtra {
            Text("Status: \(model.sessionStatus.label)")
            if model.sessionStatus == .connected {
                Text("Location: \(model.connectedRegion?.displayName ?? "Unknown")")
                Text("Protocol: \(model.connectedTransport?.displayName ?? "Unknown")")
            }
            Divider()
            if model.sessionStatus == .connected {
                Button("Disconnect", role: .destructive) {
                    Task { await model.disconnect(using: tunnel) }
                }
                .disabled(model.isBusy)
            } else {
                Button("Quick Connect") {
                    Task { await model.quickConnect(using: tunnel) }
                }
                .disabled(!model.isAuthenticated || model.isBusy || model.regions.isEmpty)
            }
            Divider()
            Button("Open PrivateClient") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("Quit PrivateClient") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(model.sessionStatus == .connected ? "menubar-connected" : "menubar-disconnected")
                .renderingMode(.template)
        }
    }
}
