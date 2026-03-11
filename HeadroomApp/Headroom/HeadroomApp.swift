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
                .task {
                    // Auto-start collection if DB exists (returning user)
                    if collector.dbExists {
                        collector.start()
                    }
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 750)
    }
}
