import CarPlay
import os

private let log = Logger(subsystem: "com.ghost.easy", category: "carplay")

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    private var listTemplate: CPListTemplate?
    private var observationTask: Task<Void, Never>?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        log.info("CarPlay connected")
        self.interfaceController = interfaceController

        let template = makeListTemplate()
        self.listTemplate = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        Task { @MainActor in
            VoiceViewModel.shared.isCarPlayConnected = true
        }

        startObserving()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        log.info("CarPlay disconnected")
        observationTask?.cancel()
        observationTask = nil
        self.interfaceController = nil
        self.listTemplate = nil

        Task { @MainActor in
            VoiceViewModel.shared.isCarPlayConnected = false
        }
    }

    // MARK: - Template

    private func makeListTemplate() -> CPListTemplate {
        let statusSection = CPListSection(
            items: [makeStatusItem(status: .idle, isActivated: false, recognizedText: "")],
            header: "Status",
            sectionIndexTitle: nil
        )
        let messagesSection = CPListSection(
            items: [makeEmptyItem()],
            header: "Recent",
            sectionIndexTitle: nil
        )
        let template = CPListTemplate(title: "Easy", sections: [statusSection, messagesSection])
        return template
    }

    private func makeStatusItem(
        status: VoiceViewModel.Status,
        isActivated: Bool,
        recognizedText: String
    ) -> CPListItem {
        let (text, detail) = statusDisplay(status: status, isActivated: isActivated, recognizedText: recognizedText)
        let item = CPListItem(text: text, detailText: detail)
        item.handler = nil
        return item
    }

    private func statusDisplay(
        status: VoiceViewModel.Status,
        isActivated: Bool,
        recognizedText: String
    ) -> (String, String) {
        switch status {
        case .idle:
            return ("Idle", "Not active")
        case .listening:
            if !recognizedText.isEmpty {
                return ("Listening", recognizedText)
            } else if isActivated {
                return ("Listening...", "Speak now")
            } else {
                return ("Waiting", "Say \"easy\" to start")
            }
        case .thinking:
            return ("Thinking...", recognizedText.isEmpty ? "Processing" : String(recognizedText.prefix(80)))
        case .speaking:
            return ("Speaking...", "Playing response")
        }
    }

    private func makeMessageItem(message: Message) -> CPListItem {
        let prefix = message.role == .user ? "You" : "AI"
        let truncated = String(message.text.prefix(120))
        let item = CPListItem(text: "\(prefix): \(truncated)", detailText: nil)
        item.handler = nil
        return item
    }

    private func makeEmptyItem() -> CPListItem {
        let item = CPListItem(text: "No messages yet", detailText: nil)
        item.handler = nil
        return item
    }

    // MARK: - Observation

    private func startObserving() {
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let vm = VoiceViewModel.shared

            var lastStatus = vm.status
            var lastMessageCount = vm.messages.count
            var lastActivated = vm.isActivated
            var lastRecognizedText = vm.recognizedText

            self.updateTemplate(vm: vm)

            while !Task.isCancelled {
                // Use withObservationTracking to detect changes
                let changed: Bool = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = vm.status
                        _ = vm.messages.count
                        _ = vm.isActivated
                        _ = vm.recognizedText
                    } onChange: {
                        continuation.resume(returning: true)
                    }
                }

                guard changed, !Task.isCancelled else { continue }

                // Small debounce to batch rapid changes
                try? await Task.sleep(for: .milliseconds(100))

                if vm.status != lastStatus
                    || vm.messages.count != lastMessageCount
                    || vm.isActivated != lastActivated
                    || vm.recognizedText != lastRecognizedText
                {
                    lastStatus = vm.status
                    lastMessageCount = vm.messages.count
                    lastActivated = vm.isActivated
                    lastRecognizedText = vm.recognizedText
                    self.updateTemplate(vm: vm)
                }
            }
        }
    }

    @MainActor
    private func updateTemplate(vm: VoiceViewModel) {
        guard let listTemplate else { return }

        let statusItem = makeStatusItem(
            status: vm.status,
            isActivated: vm.isActivated,
            recognizedText: vm.recognizedText
        )
        let statusSection = CPListSection(
            items: [statusItem],
            header: "Status",
            sectionIndexTitle: nil
        )

        let recentMessages = vm.messages.suffix(4)
        let messageItems: [CPListItem] = recentMessages.isEmpty
            ? [makeEmptyItem()]
            : recentMessages.map { makeMessageItem(message: $0) }
        let messagesSection = CPListSection(
            items: messageItems,
            header: "Recent",
            sectionIndexTitle: nil
        )

        listTemplate.updateSections([statusSection, messagesSection])
    }
}
