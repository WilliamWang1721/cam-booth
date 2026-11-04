import SwiftUI

@main
struct CamBoothApp: App {
    var body: some Scene {
        WindowGroup("Cam Booth") {
            ContentView()
                .frame(minWidth: 480, minHeight: 400)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
