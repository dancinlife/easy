import SwiftUI

struct SessionListView: View {
    @Bindable var vm: VoiceViewModel
    @Binding var path: NavigationPath
    @State private var showSettings = false
    @State private var showQRScanner = false

    var body: some View {
        List {
            ForEach(vm.sessionStore.sessions) { session in
                Button {
                    vm.switchSession(id: session.id)
                    path.append(session.id)
                } label: {
                    HStack(spacing: 10) {
                        // Connection status dot
                        Circle()
                            .fill(sessionDotColor(session))
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if let lastMsg = session.messages.last {
                                Text(lastMsg.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            HStack(spacing: 6) {
                                Text(session.createdAt.formatted(.relative(presentation: .named)))
                                Text("\u{00B7}")
                                Text("\(session.messages.count) msgs")

                                if let hostname = session.hostname {
                                    Text("\u{00B7}")
                                    Text(hostname.replacingOccurrences(of: ".local", with: ""))
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let session = vm.sessionStore.sessions[index]
                    vm.deleteSession(id: session.id)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        .overlay {
            if vm.sessionStore.sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "qrcode.viewfinder",
                    description: Text("Run easy on your Mac\nand scan the QR code")
                )
            }
        }
        .navigationTitle("Easy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Button { showQRScanner = true } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { info in
                vm.startNewSession(with: info)
                path.append(vm.currentSessionId ?? "")
            }
        }
    }

    private func sessionDotColor(_ session: Session) -> Color {
        guard let room = session.room,
              room == vm.pairedRoom else {
            return .gray
        }
        switch vm.relayState {
        case .disconnected: return .red
        case .connecting: return .orange
        case .connected: return .yellow
        case .paired: return .green
        }
    }
}
