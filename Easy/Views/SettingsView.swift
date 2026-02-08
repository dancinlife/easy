import SwiftUI

struct SettingsView: View {
    @Bindable var vm: VoiceViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("음성 인식") {
                    SecureField("OpenAI API 키", text: $vm.openAIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()

                    Picker("입력 언어", selection: $vm.sttLanguage) {
                        Text("English").tag("en")
                        Text("한국어").tag("ko")
                    }

                    HStack {
                        Text("침묵 감지")
                        Slider(value: $vm.silenceTimeout, in: 1.0...3.0, step: 0.5)
                        Text("\(vm.silenceTimeout, specifier: "%.1f")초")
                            .monospacedDigit()
                    }
                }

                Section {
                    Picker("음성", selection: $vm.ttsVoice) {
                        Text("Alloy").tag("alloy")
                        Text("Ash").tag("ash")
                        Text("Ballad").tag("ballad")
                        Text("Coral").tag("coral")
                        Text("Echo").tag("echo")
                        Text("Fable").tag("fable")
                        Text("Nova").tag("nova")
                        Text("Onyx").tag("onyx")
                        Text("Sage").tag("sage")
                        Text("Shimmer").tag("shimmer")
                    }

                    Toggle("자동 듣기", isOn: $vm.autoListen)
                } header: {
                    Text("TTS")
                } footer: {
                    Text("TTS 재생 완료 후 자동으로 음성 인식을 재시작합니다.")
                }

                Section("정보") {
                    LabeledContent("버전", value: "2.0.0")
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
}
