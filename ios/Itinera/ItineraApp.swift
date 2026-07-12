import SwiftUI

@main
struct ItineraApp: App {
    @StateObject private var appState: AppState

    init() {
        _appState = StateObject(wrappedValue: AppState.live())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await appState.loadPendingJobs()
                    await appState.resumePendingSubmissions()
                }
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
