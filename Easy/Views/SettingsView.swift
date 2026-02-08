import SwiftUI

struct SettingsView: View {
    @Bindable var vm: VoiceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showQRScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Relay 연결") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("상태")
                            Text(relayStatusText)
                                .font(.caption)
                                .foregroundStyle(relayStatusColor)
                        }

                        Spacer()

                        Button {
                            showQRScanner = true
                        } label: {
                            Label("QR 스캔", systemImage: "qrcode.viewfinder")
                        }
                    }

                    Button {
                        if let str = UIPasteboard.general.string,
                           let url = URL(string: str) {
                            vm.handlePairingURL(url)
                        }
                    } label: {
                        Label("클립보드에서 붙여넣기", systemImage: "doc.on.clipboard")
                    }

                    if let url = vm.pairedRelayURL {
                        LabeledContent("Relay", value: url)
                            .font(.caption2)
                    }

                    if let room = vm.pairedRoom {
                        LabeledContent("Room", value: String(room.prefix(8)) + "...")
                            .font(.caption2)
                    }
                }

                Section("음성 인식 (Whisper)") {
                    SecureField("OpenAI API 키", text: $vm.openAIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()

                    Picker("입력 언어", selection: $vm.sttLanguage) {
                        Text("English").tag("en")
                        Text("한국어").tag("ko")
                    }
                    .pickerStyle(.segmented)

                    Toggle("자동 듣기 (TTS 후 바로 재시작)", isOn: $vm.autoListen)

                    HStack {
                        Text("침묵 감지")
                        Slider(value: $vm.silenceTimeout, in: 1.0...3.0, step: 0.5)
                        Text("\(vm.silenceTimeout, specifier: "%.1f")초")
                            .monospacedDigit()
                    }
                }

                Section("정보") {
                    LabeledContent("버전", value: "2.0.0")
                    LabeledContent("상태") {
                        Text(relayStatusText)
                            .foregroundStyle(relayStatusColor)
                    }
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { info in
                    vm.configureRelay(with: info)
                }
            }
        }
    }

    private var relayStatusText: String {
        switch vm.relayState {
        case .disconnected: "연결 안됨"
        case .connecting: "연결 중..."
        case .connected: "연결됨 (키교환 대기)"
        case .paired: "페어링 완료"
        }
    }

    private var relayStatusColor: Color {
        switch vm.relayState {
        case .disconnected: .red
        case .connecting: .orange
        case .connected: .yellow
        case .paired: .green
        }
    }
}
