import SwiftUI

struct VoiceView: View {
    @Bindable var vm: VoiceViewModel
    @State private var isPulsing = false
    @State private var isScrollReady = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    Color.clear.frame(height: 0).id("bottom") // VStack spacing(8pt)이 하단 여백
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .defaultScrollAnchor(.bottom)
            .opacity(isScrollReady ? 1 : 0)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                    isScrollReady = true
                }
            }
            .onChange(of: vm.messages.count) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
        }
        .navigationTitle(currentSessionName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { toolbarItems }
        .onAppear {
            if vm.status == .idle && vm.relayState == .paired {
                vm.startListening()
            }
        }
        .onDisappear {
            vm.stopAll()
        }
        .onChange(of: vm.relayState) { _, newState in
            if newState == .paired && vm.status == .idle {
                vm.startListening()
            }
        }
        .onChange(of: vm.status) { _, newStatus in
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                isPulsing = (newStatus == .listening)
            }
            if newStatus != .listening {
                withAnimation(.easeOut(duration: 0.2)) {
                    isPulsing = false
                }
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch vm.status {
        case .idle:
            Text("Tap to start")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .listening:
            if !vm.recognizedText.isEmpty {
                Text(vm.recognizedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if vm.isActivated {
                HStack(spacing: 4) {
                    Image(systemName: "ear")
                        .font(.caption2)
                    Text("Listening...")
                        .font(.caption)
                }
                .foregroundStyle(.green)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.caption2)
                    Text("Say \"easy\" to start")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        case .thinking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking...")
                    .font(.caption)
            }
            .foregroundStyle(.orange)
        case .speaking:
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption2)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text("Speaking...")
                    .font(.caption)
            }
            .foregroundStyle(.purple)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Divider()

            statusText
                .padding(.horizontal, 16)

            if !vm.debugLog.isEmpty {
                Text(vm.debugLog)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.gray)
                    .padding(.horizontal, 16)
            }

            if let error = vm.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            HStack {
                Spacer()

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
                        if vm.status == .listening {
                            Circle()
                                .stroke(micColor.opacity(0.3), lineWidth: 2)
                                .frame(width: 72, height: 72)
                                .scaleEffect(isPulsing ? 1.3 : 1.0)
                                .opacity(isPulsing ? 0 : 0.8)

                            Circle()
                                .stroke(micColor.opacity(0.2), lineWidth: 2)
                                .frame(width: 72, height: 72)
                                .scaleEffect(isPulsing ? 1.6 : 1.0)
                                .opacity(isPulsing ? 0 : 0.5)
                        }

                        Circle()
                            .fill(micColor)
                            .frame(width: 56, height: 56)

                        Image(systemName: micIcon)
                            .font(.title3)
                            .foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative, isActive: vm.status == .thinking)
                    }
                }
                .disabled(vm.status == .thinking || vm.status == .speaking)

                Spacer()

                Button {
                    vm.speakerMode.toggle()
                } label: {
                    Image(systemName: vm.speakerMode ? "speaker.wave.3.fill" : "speaker.wave.1")
                        .font(.body)
                        .foregroundStyle(vm.speakerMode ? .orange : .secondary)
                        .frame(width: 44, height: 44)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                statusBadge
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                statusBadge
            }
        }
    }

    private var statusBadge: some View {
        Text(statusLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(statusLabelColor)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusLabelColor.opacity(0.15)))
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

    private var statusLabel: String {
        switch vm.relayState {
        case .disconnected: "Off"
        case .connecting: "Wait"
        case .connected: "Wait"
        case .paired: "Live"
        }
    }

    private var statusLabelColor: Color {
        switch vm.relayState {
        case .disconnected: .red
        case .connecting, .connected: .orange
        case .paired: .green
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
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

#Preview {
    VoiceView(vm: VoiceViewModel())
}
