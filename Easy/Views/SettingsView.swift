import SwiftUI

struct SettingsView: View {
    @Bindable var vm: VoiceViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Speech Recognition") {
                    SecureField("OpenAI API Key", text: $vm.openAIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()

                    Picker("Language", selection: $vm.sttLanguage) {
                        Text("English").tag("en")
                        Text("Korean").tag("ko")
                    }

                    HStack {
                        Text("Silence Detection")
                        Slider(value: $vm.silenceTimeout, in: 1.0...3.0, step: 0.5)
                        Text("\(vm.silenceTimeout, specifier: "%.1f")s")
                            .monospacedDigit()
                    }
                }

                Section {
                    Picker("Voice", selection: $vm.ttsVoice) {
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

                    Toggle("Auto Listen", isOn: $vm.autoListen)
                } header: {
                    Text("TTS")
                } footer: {
                    Text("Automatically restarts voice recognition after TTS playback.")
                }

                Section("Info") {
                    LabeledContent("Version", value: "2.0.0")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
