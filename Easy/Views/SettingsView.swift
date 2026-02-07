import SwiftUI

struct SettingsView: View {
    @Bindable var vm: VoiceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""
    @State private var showQRScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section("연결 방식") {
                    Picker("모드", selection: $vm.connectionMode) {
                        ForEach(VoiceViewModel.ConnectionMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if vm.connectionMode == .direct {
                    Section("직접 연결") {
                        TextField("Tailscale IP (100.x.x.x)", text: $vm.serverHost)
                            .keyboardType(.decimalPad)
                            .autocorrectionDisabled()

                        TextField("포트", text: $portText)
                            .keyboardType(.numberPad)
                            .onAppear { portText = String(vm.serverPort) }
                            .onChange(of: portText) {
                                vm.serverPort = Int(portText) ?? 7777
                            }
                    }
                } else {
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

                        if let url = vm.pairedRelayURL {
                            LabeledContent("Relay", value: url)
                                .font(.caption2)
                        }

                        if let room = vm.pairedRoom {
                            LabeledContent("Room", value: String(room.prefix(8)) + "...")
                                .font(.caption2)
                        }
                    }
                }

                Section("Claude Code") {
                    TextField("작업 폴더 (예: ~/Dev/myproject)", text: $vm.workDir)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("음성") {
                    Toggle("자동 듣기 (TTS 후 바로 재시작)", isOn: $vm.autoListen)

                    HStack {
                        Text("TTS 속도")
                        Slider(value: Binding(
                            get: { Double(vm.tts.speechRate) },
                            set: { vm.tts.speechRate = Float($0) }
                        ), in: 0.3...0.7, step: 0.05)
                    }

                    HStack {
                        Text("침묵 감지")
                        Slider(value: $vm.speech.silenceTimeout, in: 1.0...3.0, step: 0.5)
                        Text("\(vm.speech.silenceTimeout, specifier: "%.1f")초")
                            .monospacedDigit()
                    }
                }

                Section("정보") {
                    LabeledContent("버전", value: "1.1.0")
                    LabeledContent("상태") {
                        Text(statusText)
                            .foregroundStyle(statusColor)
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

    private var statusText: String {
        switch vm.connectionMode {
        case .direct:
            return vm.serverHost.isEmpty ? "서버 미설정" : "준비됨"
        case .relay:
            return relayStatusText
        }
    }

    private var statusColor: Color {
        switch vm.connectionMode {
        case .direct:
            return vm.serverHost.isEmpty ? .red : .green
        case .relay:
            return relayStatusColor
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
