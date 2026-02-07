import SwiftUI

struct SettingsView: View {
    @Bindable var vm: VoiceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("서버 연결") {
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
                    LabeledContent("버전", value: "1.0.0")
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
        }
    }

    private var statusText: String {
        vm.serverHost.isEmpty ? "서버 미설정" : "준비됨"
    }

    private var statusColor: Color {
        vm.serverHost.isEmpty ? .red : .green
    }
}
