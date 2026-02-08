import SwiftUI

struct VoiceView: View {
    @Bindable var vm: VoiceViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Messages — 채팅 스타일 (하단 정렬)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(vm.messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    if let last = vm.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: vm.messages.count) {
                    if let last = vm.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Bottom bar
            VStack(spacing: 4) {
                Divider()

                // Status / recognized text
                if vm.status == .listening && !vm.recognizedText.isEmpty {
                    Text(vm.recognizedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                } else if vm.status == .thinking {
                    Text(vm.recognizedText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }

                // Error
                if let error = vm.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }

                // Controls
                HStack {
                    Button(action: { vm.stopAll() }) {
                        Image(systemName: "stop.fill")
                            .font(.body)
                            .foregroundStyle(.red)
                            .frame(width: 44, height: 44)
                    }
                    .opacity(vm.status != .idle ? 1 : 0.3)
                    .disabled(vm.status == .idle)

                    Spacer()

                    Button(action: { vm.startListening() }) {
                        ZStack {
                            Circle()
                                .fill(micColor)
                                .frame(width: 52, height: 52)
                                .shadow(color: micColor.opacity(0.4), radius: vm.status == .listening ? 8 : 0)

                            Image(systemName: micIcon)
                                .font(.title3)
                                .foregroundStyle(.white)
                        }
                    }
                    .disabled(vm.status == .thinking || vm.status == .speaking)

                    Spacer()

                    // Relay indicator
                    HStack(spacing: 3) {
                        Circle()
                            .fill(relayDotColor)
                            .frame(width: 6, height: 6)
                        Text(relayStatusLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 44, height: 44)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            .background(.bar)
        }
        .navigationTitle(currentSessionName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            if vm.status == .idle && vm.relayState == .paired {
                vm.startListening()
            }
        }
    }

    private var currentSessionName: String {
        guard let id = vm.currentSessionId,
              let session = vm.sessionStore.sessions.first(where: { $0.id == id }) else {
            return "Easy"
        }
        return session.name
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
        case .disconnected: "끊김"
        case .connecting: "연결중"
        case .connected: "연결됨"
        case .paired: "E2E"
        }
    }
}

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            Text(message.text)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(message.role == .user ? Color.blue : Color(.systemGray5))
                .foregroundStyle(message.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }
}

#Preview {
    VoiceView(vm: VoiceViewModel())
}
