import SwiftUI

@main
struct ItineraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            TripFormView()
                .tabItem { Label("New Trip", systemImage: "plus.circle.fill") }
            SavedTripsView()
                .tabItem { Label("My Trips", systemImage: "suitcase.fill") }
        }
    }
}
