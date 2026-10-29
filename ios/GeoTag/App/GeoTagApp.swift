import SwiftUI
import ARCore

@main
struct GeoTagApp: App {
    var body: some Scene {
        WindowGroup {
            Text("geo#").font(.largeTitle)
                .onAppear { _ = GARSessionConfiguration() }
        }
    }
}
