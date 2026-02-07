import SwiftUI

struct VoiceView: View {
    @State private var vm = VoiceViewModel()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(vm.messages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: vm.messages.count) {
                        if let last = vm.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                // Status & recognized text
                if vm.status == .listening && !vm.speech.recognizedText.isEmpty {
                    Text(vm.speech.recognizedText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                }

                // Error
                if let error = vm.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                }

                // Controls
                HStack(spacing: 24) {
                    Button(action: { vm.stopAll() }) {
                        Image(systemName: "stop.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                    .opacity(vm.status != .idle ? 1 : 0.3)
                    .disabled(vm.status == .idle)

                    Button(action: { vm.startListening() }) {
                        ZStack {
                            Circle()
                                .fill(micColor)
                                .frame(width: 72, height: 72)
                                .shadow(color: micColor.opacity(0.5), radius: vm.status == .listening ? 12 : 0)

                            Image(systemName: micIcon)
                                .font(.title)
                                .foregroundStyle(.white)
                        }
                    }
                    .disabled(vm.status == .thinking || vm.status == .speaking)

                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Easy")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) {
                SettingsView(vm: vm)
            }
        }
    }

    private var micColor: Color {
        switch vm.status {
        case .idle: .blue
        case .listening: .green
        case .thinking: .orange
        case .speaking: .purple
        }
    }

    private var micIcon: String {
        switch vm.status {
        case .idle: "mic.fill"
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        }
    }
}

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            Text(message.text)
                .padding(12)
                .background(message.role == .user ? Color.blue : Color(.systemGray5))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }
}

#Preview {
    VoiceView()
}
