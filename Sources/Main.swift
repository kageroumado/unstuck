import SwiftUI

@main
struct UnstuckApp: App {
    @State private var monitor = Monitor()

    var body: some Scene {
        Window("Unstuck", id: "main") {
            ContentView(monitor: monitor)
                .task {
                    monitor.start()
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 920, height: 1040)
    }
}
