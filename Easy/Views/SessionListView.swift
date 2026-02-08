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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            if let workDir = session.workDir {
                                Text("~/\((workDir as NSString).lastPathComponent)")
                                Text("\u{00B7}")
                            }
                            Text(session.createdAt.formatted(.relative(presentation: .named)))
                            Text("\u{00B7}")
                            Text("\(session.messages.count)개 메시지")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                    "세션 없음",
                    systemImage: "qrcode.viewfinder",
                    description: Text("Mac에서 easy를 실행하고\nQR 코드를 스캔하세요")
                )
            }
        }
        .navigationTitle("Easy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(relayDotColor)
                        .frame(width: 8, height: 8)
                    Text(relayStatusLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    Button { showQRScanner = true } label: {
                        Image(systemName: "qrcode.viewfinder")
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

    private var relayDotColor: Color {
        switch vm.relayState {
        case .disconnected: .red
        case .connecting: .orange
        case .connected: .yellow
        case .paired: .green
        }
    }

    private var relayStatusLabel: String {
        switch vm.relayState {
        case .disconnected: "연결 안됨"
        case .connecting: "연결 중..."
        case .connected: "연결됨"
        case .paired: "E2E 암호화"
        }
    }
}
