import SwiftUI

struct SettingsView: View {
    @Bindable var vm: VoiceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingKey = false
    @State private var keyDraft = ""
    @State private var testResult: TestResult?
    @State private var isTesting = false
    @State private var savedKeyValid: Bool?
    @State private var isValidating = false
    @State private var showCopied = false
    @State private var showReenterAlert = false

    enum TestResult {
        case success, failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if vm.openAIKey.isEmpty || isEditingKey {
                        // Input mode
                        SecureField("sk-...", text: $keyDraft)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        HStack {
                            Button {
                                testAPIKey()
                            } label: {
                                HStack(spacing: 4) {
                                    if isTesting {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text("Test")
                                }
                            }
                            .disabled(keyDraft.isEmpty || isTesting)

                            Spacer()

                            Button("Save") {
                                vm.openAIKey = keyDraft
                                isEditingKey = false
                                testResult = nil
                            }
                            .disabled(testResult == nil || {
                                if case .success = testResult { return false }
                                return true
                            }())
                        }

                        if let result = testResult {
                            switch result {
                            case .success:
                                Label("Valid", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            case .failure(let msg):
                                Label(msg, systemImage: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    } else {
                        // Saved mode
                        HStack {
                            if isValidating {
                                ProgressView().controlSize(.small)
                            } else if let valid = savedKeyValid {
                                Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(valid ? .green : .red)
                                    .font(.caption)
                            }

                            Text(maskedKey)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(savedKeyValid == true ? .primary : .secondary)

                            Spacer()

                            Button {
                                UIPasteboard.general.string = vm.openAIKey
                                showCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    showCopied = false
                                }
                            } label: {
                                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(showCopied ? .green : .secondary)
                            }
                            .buttonStyle(.borderless)

                            Button {
                                showReenterAlert = true
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if vm.openAIKey.isEmpty && !isEditingKey {
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

                    Stepper(
                        "Silence \(String(format: "%.1f", vm.silenceTimeout))s",
                        value: $vm.silenceTimeout,
                        in: 1.0...10.0,
                        step: 0.5
                    )
                    .monospacedDigit()
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
                    .pickerStyle(.segmented)

                    Toggle("Auto Listen", isOn: $vm.autoListen)
                } header: {
                    Text("TTS")
                } footer: {
                    Text("Automatically restarts voice recognition after TTS playback.")
                }

                Section("Appearance") {
                    Picker("Theme", selection: $vm.theme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Info") {
                    LabeledContent("Version", value: "2.0.0")
                }
            }
            .onAppear { validateSavedKey() }
            .alert("Re-enter API Key?", isPresented: $showReenterAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Re-enter", role: .destructive) {
                    keyDraft = ""
                    testResult = nil
                    savedKeyValid = nil
                    isEditingKey = true
                }
            } message: {
                Text("The current key will be replaced after entering and testing a new one.")
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

    private var maskedKey: String {
        let key = vm.openAIKey
        guard key.count > 8 else { return String(repeating: "*", count: key.count) }
        return String(key.prefix(4)) + "..." + String(key.suffix(4))
    }

    private func validateSavedKey() {
        guard !vm.openAIKey.isEmpty, !isEditingKey else { return }
        isValidating = true
        savedKeyValid = nil

        Task {
            savedKeyValid = await checkKey(vm.openAIKey)
            isValidating = false
        }
    }

    private func testAPIKey() {
        isTesting = true
        testResult = nil

        Task {
            let valid = await checkKey(keyDraft)
            testResult = valid ? .success : .failure("Invalid key")
            isTesting = false
        }
    }

    private func checkKey(_ key: String) async -> Bool {
        do {
            let url = URL(string: "https://api.openai.com/v1/models")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
