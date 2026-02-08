import SwiftUI

@main
struct EasyApp: App {
    @State private var vm = VoiceViewModel()
    @State private var navigationPath = NavigationPath()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $navigationPath) {
                SessionListView(vm: vm, path: $navigationPath)
                    .navigationDestination(for: String.self) { _ in
                        VoiceView(vm: vm)
                    }
            }
            .onOpenURL { url in
                vm.handlePairingURL(url)
            }
            .onAppear {
                vm.restorePairingIfNeeded()
            }
            .onChange(of: vm.pendingNavigateToSession) { _, sessionId in
                if let sessionId {
                    navigationPath = NavigationPath()
                    navigationPath.append(sessionId)
                    vm.pendingNavigateToSession = nil
                }
            }
            .preferredColorScheme(vm.preferredColorScheme)
        }
    }
}
