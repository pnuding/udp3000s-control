import SwiftUI

@main
struct UDP3000SControlApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        // A real separate window (not a popover) so it can stay open
        // permanently alongside the main window while you keep working.
        Window("Graph", id: "graph") {
            GraphView()
                .environmentObject(model)
                .padding()
                .frame(minWidth: 480, minHeight: 480)
        }
    }
}
