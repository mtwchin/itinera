import SwiftUI

@main
struct ItineraApp: App {
    @StateObject private var tripStore = TripStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(tripStore)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            PlanView()
                .tabItem { Label("Plan", systemImage: "wand.and.stars") }

            TripsView()
                .tabItem { Label("My Trips", systemImage: "suitcase") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(TripStore())
}
