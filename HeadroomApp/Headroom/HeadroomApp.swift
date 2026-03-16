import SwiftUI

@main
struct HeadroomApp: App {
    @State private var database = HeadroomDatabase()
    @State private var collector = CollectorManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(database)
                .environment(collector)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 750)
    }
}
