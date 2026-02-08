import SwiftUI

struct SettingsView: View {
    @Bindable var vm: VoiceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAPIKey = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OpenAI API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            if showAPIKey {
                                TextField("sk-...", text: $vm.openAIKey)
                                    .font(.system(.body, design: .monospaced))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            } else {
                                SecureField("sk-...", text: $vm.openAIKey)
                                    .autocorrectionDisabled()
                            }
                            Button {
                                showAPIKey.toggle()
                            } label: {
                                Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            if !vm.openAIKey.isEmpty {
                                Button {
                                    UIPasteboard.general.string = vm.openAIKey
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if vm.openAIKey.isEmpty {
                        Label("Required for Whisper STT and TTS", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("Used for both speech recognition (Whisper) and text-to-speech.")
                }

                Section("Speech Recognition") {
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

                    Picker("Speed", selection: $vm.ttsSpeed) {
                        Text("Normal").tag(1.0)
                        Text("Fast").tag(1.5)
                        Text("Very Fast").tag(2.0)
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
