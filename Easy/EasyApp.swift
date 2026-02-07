import SwiftUI

@main
struct EasyApp: App {
    @State private var vm = VoiceViewModel()

    var body: some Scene {
        WindowGroup {
            VoiceView(vm: vm)
                .onOpenURL { url in
                    vm.handlePairingURL(url)
                }
        }
    }
}
