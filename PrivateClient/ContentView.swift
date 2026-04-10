import Partout
import SwiftUI

struct ContentView: View {
    @State
    private var model = AppModel()

    @State
    private var tunnel = TunnelObservable.shared

    private let refreshTimer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !model.isSignedIn {
                loginView
            } else {
                mainView
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.synchronize(with: tunnel)
        }
        .onReceive(refreshTimer) { _ in
            Task {
                await model.synchronize(with: tunnel)
            }
        }
    }
}

private extension ContentView {
    var loginView: some View {
        VStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("PrivateClient")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Unofficial macOS client for Private Internet Access built on Partout.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("PIA Username")
                        .font(.caption.weight(.semibold))
                    TextField("p1234567", text: $model.username)
                        .textFieldStyle(.roundedBorder)

                    Text("PIA Password")
                        .font(.caption.weight(.semibold))
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                Button("Sign In") {
                    Task { await model.signIn() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSignIn || model.isBusy)
            }
            .padding(24)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 28)
    }

    var mainView: some View {
        VStack(spacing: 16) {
            header
            HSplitView {
                serverListPane
                detailPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Server Browser")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(model.sessionStatus.label)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button("Refresh") {
                    Task { await model.refreshRegions() }
                }
                .disabled(model.isBusy)

                Button("Sign Out") {
                    Task { await model.signOut(using: tunnel) }
                }
                .disabled(model.isBusy)
            }
        }
    }

    var serverListPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search regions", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            List(selection: $model.selectedRegionID) {
                ForEach(model.filteredRegions) { region in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(region.name)
                            .font(.headline)
                        HStack {
                            Text(region.country)
                            if region.geo == true {
                                Text("Geo")
                            }
                            if region.portForward == true {
                                Text("PF")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(region.id)
                }
            }
        }
        .frame(minWidth: 280, maxWidth: 340)
    }

    var detailPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusCard
            protocolPicker
            connectionButtons
            logPane
        }
        .padding(.leading, 20)
    }

    var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectedRegion?.name ?? "No Region Selected")
                .font(.title2.weight(.semibold))
            Text(model.selectedTransport.displayName)
                .foregroundStyle(.secondary)
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    var protocolPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Protocol")
                .font(.headline)
            Picker("Protocol", selection: $model.selectedTransport) {
                ForEach(VPNTransport.allCases) { transport in
                    Text(transport.displayName).tag(transport)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    var connectionButtons: some View {
        HStack {
            Button("Connect") {
                Task { await model.connect(using: tunnel) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canConnect)

            Button("Disconnect") {
                Task { await model.disconnect(using: tunnel) }
            }
            .disabled(model.currentProfileID == nil || model.isBusy)
        }
    }

    var logPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Log")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.logLines.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
