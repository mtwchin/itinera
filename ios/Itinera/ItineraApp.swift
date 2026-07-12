import Foundation
import SwiftUI

@main
struct ItineraApp: App {
    @StateObject private var appState: AppState
    private let theme: ItineraTheme

    init() {
        _appState = StateObject(wrappedValue: AppState.live())
        theme = ItineraAesthetic.selected.theme
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environment(\.itineraTheme, theme)
                .tint(theme.accent)
                .preferredColorScheme(theme.preferredColorScheme)
                .task {
                    await appState.loadPendingJobs()
                    await appState.resumePendingSubmissions()
                }
        }
    }
}

struct ContentView: View {
    private enum Tab: Hashable {
        case plan
        case popular
        case trips
    }

    @Environment(\.itineraTheme) private var theme
    @State private var selectedTab: Tab = .plan

    var body: some View {
        #if DEBUG
        debugRoot
        #else
        tabs
        #endif
    }

    @ViewBuilder
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            TripFormView()
                .tabItem { Label("Plan", systemImage: "map.fill") }
                .tag(Tab.plan)
            PopularItinerariesView()
                .tabItem { Label("Popular", systemImage: "flame.fill") }
                .tag(Tab.popular)
            SavedTripsView(onPlanTrip: { selectedTab = .plan })
                .tabItem { Label("Trips", systemImage: "suitcase.fill") }
                .tag(Tab.trips)
        }
        .toolbarBackground(theme.surface.opacity(0.96), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    #if DEBUG
    @ViewBuilder
    private var debugRoot: some View {
        if ProcessInfo.processInfo.environment["ITINERA_DEMO_SCREEN"] == "itinerary" {
            NavigationStack {
                ItineraryView(itinerary: .preview)
                    .navigationTitle("Lisbon, Portugal")
            }
        } else {
            tabs
        }
    }
    #endif
}
