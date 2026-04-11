import Partout
import SwiftUI

struct ContentView: View {
    @Bindable
    var model: AppModel

    var tunnel: TunnelObservable

    @State
    private var connectedSince: Date?

    @State
    private var timerNow = Date()

    @State
    private var isLogVisible = false

    @State
    private var columnVisibility: NavigationSplitViewVisibility = .automatic

    private let refreshTimer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()
    private let clockTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        if !model.isSignedIn {
            loginView
                .task {
                    await model.synchronize(with: tunnel)
                }
                .onReceive(refreshTimer) { _ in
                    Task { await model.synchronize(with: tunnel) }
                }
                .onReceive(clockTimer) { now in
                    timerNow = now
                }
        } else {
            mainView
                .task {
                    await model.synchronize(with: tunnel)
                }
                .onReceive(refreshTimer) { _ in
                    Task { await model.synchronize(with: tunnel) }
                }
                .onReceive(clockTimer) { now in
                    timerNow = now
                }
                .onChange(of: model.sessionStatus) { _, newStatus in
                    if newStatus == .connected {
                        if connectedSince == nil {
                            connectedSince = Date()
                        }
                    } else {
                        connectedSince = nil
                    }
                }
        }
    }
}

private extension ContentView {
    var loginView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue.gradient)
                
                Text("PrivateClient")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                
                Text("Unofficial macOS client for Private Internet Access.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PIA Username")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("p1234567", text: $model.username)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("PIA Password")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
                }

                if let errorMessage = model.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(errorMessage)
                    }
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await model.signIn() }
                } label: {
                    HStack {
                        if model.isBusy {
                            ProgressView().controlSize(.small).padding(.trailing, 4)
                        }
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canSignIn || model.isBusy)
            }
            .padding(40)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
            .shadow(color: .black.opacity(0.1), radius: 30, x: 0, y: 15)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    var mainView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            serverListPane
                .navigationSplitViewColumnWidth(ideal: 300, max: 400)
                .navigationTitle("Servers")
                .safeAreaBar(edge: .bottom) {
                    if let connectedRegion = model.connectedRegion {
                        sidebarStatusCard(for: connectedRegion)
                    }
                }
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(ideal: 600)
                .navigationTitle(model.selectedRegion?.name ?? "Connection")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if columnVisibility == .detailOnly {
                            statusBadge
                        }

                        Button {
                            isLogVisible.toggle()
                        } label: {
                            Label("Show Log", systemImage: "terminal")
                        }
                        .symbolVariant(isLogVisible ? .fill : .none)
                        .help("Toggle Session Log")

                        Button {
                            Task { await model.signOut(using: tunnel) }
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .disabled(model.isBusy)
                        .help("Sign Out")
                    }
                }
        }
        .inspector(isPresented: $isLogVisible) {
            logPane
                .inspectorColumnWidth(min: 300, ideal: 350, max: 500)
        }
    }

    func sidebarStatusCard(for region: PIARegion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONNECTED")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.green)
                    Text(region.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "shield.checkered")
                    .font(.title2)
                    .foregroundStyle(.green.gradient)
            }
            
            HStack {
                Label(connectionDurationLabel, systemImage: "clock")
                Spacer()
                Text(model.connectedTransport?.displayName ?? "Unknown")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            
            Button(role: .destructive) {
                Task { await model.disconnect(using: tunnel) }
            } label: {
                Text("Disconnect")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(8)
    }

    var serverListPane: some View {
        List(selection: $model.selectedRegionID) {
            ForEach(model.filteredRegions, id: \.selectionID) { region in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(region.name)
                            .font(.headline)
                        Text(region.country)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 6) {
                        if region.geo == true {
                            Image(systemName: "globe")
                                .help("Geographic location")
                        }
                        if region.portForward == true {
                            Image(systemName: "arrow.up.right.square")
                                .help("Port Forwarding available")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                .tag(region.selectionID)
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search regions")
        .listStyle(.sidebar)
    }

    var detailPane: some View {
        ScrollView {
            VStack(spacing: 32) {
                if let region = model.selectedRegion {
                    statusCard(for: region)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        Text("SETTINGS")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                        
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Protocol")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            Picker("Protocol", selection: $model.selectedTransport) {
                                ForEach(VPNTransport.allCases) { transport in
                                    Text(transport.displayName).tag(transport)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }
                    
                    connectionControl
                } else {
                    ContentUnavailableView(
                        "No Region Selected",
                        systemImage: "map",
                        description: Text("Select a server from the list to get started.")
                    )
                    .padding(.top, 100)
                }
            }
            .padding(40)
            .frame(maxWidth: 600)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func statusCard(for region: PIARegion) -> some View {
        let isActuallyConnected = model.sessionStatus == .connected && model.connectedRegion?.id == region.id
        
        return VStack(spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isActuallyConnected ? "Protected" : "Unprotected")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(isActuallyConnected ? .green : .secondary)
                        .textCase(.uppercase)
                    
                    Text(region.name)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    
                    Text(region.country)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: isActuallyConnected ? "shield.checkered" : "shield")
                    .font(.system(size: 72))
                    .foregroundStyle(isActuallyConnected ? Color.green.gradient : Color.secondary.gradient)
            }
            
            if isActuallyConnected {
                Divider()
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Duration")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(connectionDurationLabel)
                            .font(.title2.monospacedDigit().weight(.semibold))
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Transport")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.connectedTransport?.displayName ?? "Unknown")
                            .font(.title2.weight(.semibold))
                    }
                }
            }
            
            if let errorMessage = model.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    var connectionControl: some View {
        let isActuallyConnected = model.sessionStatus == .connected && model.connectedRegion?.id == model.selectedRegion?.id
        let isBusy = model.isBusy

        return Button {
            if isActuallyConnected {
                Task { await model.disconnect(using: tunnel) }
            } else {
                Task { await model.connect(using: tunnel) }
            }
        } label: {
            HStack(spacing: 12) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isActuallyConnected ? "power.circle.fill" : "power")
                        .font(.title)
                }
                
                Text(isActuallyConnected ? "Disconnect" : (model.sessionStatus == .connected ? "Switch to Server" : "Connect Now"))
                    .font(.title3.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
        }
        .buttonStyle(.glassProminent)
        .tint(isActuallyConnected ? .red : .blue)
        .disabled(!model.canConnect && !isActuallyConnected)
    }

    var logPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.logLines.enumerated()), id: \.offset) { entry in
                    Text(entry.element)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
    }

    var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.sessionStatus.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    var statusColor: Color {
        switch model.sessionStatus {
        case .connected:
            return .green
        case .connecting, .disconnecting, .loadingServers, .signingIn:
            return .orange
        case .failed:
            return .red
        case .signedOut, .ready:
            return .secondary
        }
    }

    var connectionDurationLabel: String {
        guard let connectedSince else {
            return "00:00"
        }
        let elapsed = max(0, Int(timerNow.timeIntervalSince(connectedSince)))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
