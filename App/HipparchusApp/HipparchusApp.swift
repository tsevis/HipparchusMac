import SwiftUI

@main
struct HipparchusApp: App {
    var body: some Scene {
        Window("Hipparchus", id: "map") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
