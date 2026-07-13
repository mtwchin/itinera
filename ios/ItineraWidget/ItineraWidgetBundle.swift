import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ItineraWidgetBundle: WidgetBundle {
    var body: some Widget {
        ItineraNextStopWidget()
        TripLiveActivityWidget()
    }
}

struct ItineraNextStopWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: ItineraWidgetKind.nextStop,
            provider: ItineraNextStopProvider()
        ) { entry in
            ItineraNextStopWidgetView(entry: entry)
                .privacySensitive()
                .containerBackground(for: .widget) {
                    Color(red: 0.96, green: 0.94, blue: 0.90)
                }
                .widgetURL(entry.snapshot.flatMap {
                    ScopedTripURL.make(
                        presentationSession: $0.presentationSession
                    )
                })
        }
        .configurationDisplayName("Next stop")
        .description("See the next stop and leave-by time for today's trip.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ItineraNextStopEntry: TimelineEntry {
    let date: Date
    let snapshot: TripWidgetSnapshot?
}

struct ItineraNextStopProvider: TimelineProvider {
    func placeholder(in context: Context) -> ItineraNextStopEntry {
        ItineraNextStopEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (ItineraNextStopEntry) -> Void
    ) {
        completion(
            ItineraNextStopEntry(
                date: Date(),
                snapshot: context.isPreview ? .placeholder : TripWidgetSnapshotStore.load()
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<ItineraNextStopEntry>) -> Void
    ) {
        let now = Date()
        let entry = ItineraNextStopEntry(
            date: now,
            snapshot: TripWidgetSnapshotStore.load()
        )
        completion(
            Timeline(
                entries: [entry],
                policy: .after(now.addingTimeInterval(15 * 60))
            )
        )
    }
}

private struct ItineraNextStopWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ItineraNextStopEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "location.north.fill")
                        .foregroundStyle(Color(red: 0.69, green: 0.25, blue: 0.17))
                    Text(snapshot.tripTitle)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(snapshot.stopNumber)/\(snapshot.totalStops)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.secondary)
                }

                Text(snapshot.nextStop)
                    .font(family == .systemSmall ? .headline : .title3)
                    .fontWeight(.bold)
                    .lineLimit(family == .systemSmall ? 2 : 1)

                if let leaveBy = snapshot.leaveBy {
                    Label {
                        Text(leaveBy, style: .time)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "figure.walk.departure")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.23, green: 0.39, blue: 0.31))
                }

                Spacer(minLength: 0)
                ProgressView(value: snapshot.progress)
                    .tint(Color(red: 0.23, green: 0.39, blue: 0.31))
            }
            .foregroundStyle(Color(red: 0.10, green: 0.18, blue: 0.14))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary(snapshot))
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: "location.north.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color(red: 0.23, green: 0.39, blue: 0.31))
                Text("No active trip")
                    .font(.headline)
                Text("Open Today when your trip begins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func accessibilitySummary(_ snapshot: TripWidgetSnapshot) -> String {
        var value = "\(snapshot.tripTitle). Next stop: \(snapshot.nextStop)."
        if let leaveBy = snapshot.leaveBy {
            value += " Leave by \(leaveBy.formatted(date: .omitted, time: .shortened))."
        }
        return value
    }
}

private extension TripWidgetSnapshot {
    static let placeholder = TripWidgetSnapshot(
        presentationSession: PrivatePresentationSession(
            scope: try! PrincipalScope(
                validating: String(repeating: "0", count: PrincipalScope.digestLength)
            ),
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        ),
        tripID: "preview",
        tripTitle: "Lisbon field guide",
        dayNumber: 1,
        stopNumber: 2,
        totalStops: 5,
        currentStop: "Alfama",
        nextStop: "Miradouro da Senhora",
        leaveBy: Date().addingTimeInterval(25 * 60),
        progress: 0.25
    )
}

struct TripLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(Color(red: 0.96, green: 0.94, blue: 0.90))
                .activitySystemActionForegroundColor(Color(red: 0.16, green: 0.28, blue: 0.22))
                .privacySensitive()
                .widgetURL(
                    ScopedTripURL.make(
                        presentationSession: context.attributes.presentationSession
                    )
                )
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "location.north.fill")
                        .foregroundStyle(Color(red: 0.65, green: 0.26, blue: 0.18))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.stopNumber)/\(context.state.totalStops)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .privacySensitive()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.tripTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .privacySensitive()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 5) {
                        Text("Next: \(context.state.nextStop)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .privacySensitive()
                        ProgressView(value: context.state.progress)
                            .tint(Color(red: 0.25, green: 0.40, blue: 0.32))
                    }
                    .privacySensitive()
                }
            } compactLeading: {
                Image(systemName: "location.north.fill")
                    .foregroundStyle(Color(red: 0.65, green: 0.26, blue: 0.18))
            } compactTrailing: {
                if let leaveBy = context.state.leaveBy {
                    Text(timerInterval: Date()...max(Date(), leaveBy), countsDown: true)
                        .monospacedDigit()
                        .frame(width: 42)
                        .privacySensitive()
                } else {
                    Text("\(context.state.stopNumber)/\(context.state.totalStops)")
                        .monospacedDigit()
                        .privacySensitive()
                }
            } minimal: {
                Image(systemName: "location.north.fill")
                    .foregroundStyle(Color(red: 0.65, green: 0.26, blue: 0.18))
            }
            .widgetURL(
                ScopedTripURL.make(
                    presentationSession: context.attributes.presentationSession
                )
            )
            .keylineTint(Color(red: 0.25, green: 0.40, blue: 0.32))
        }
    }

    private func lockScreenView(
        _ context: ActivityViewContext<TripActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.tripTitle, systemImage: "location.north.fill")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("STOP \(context.state.stopNumber) OF \(context.state.totalStops)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Text(context.state.nextStop)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            HStack {
                ProgressView(value: context.state.progress)
                    .tint(Color(red: 0.25, green: 0.40, blue: 0.32))
                if let leaveBy = context.state.leaveBy {
                    Text("Leave in ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    + Text(timerInterval: Date()...max(Date(), leaveBy), countsDown: true)
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
        }
        .padding()
        .privacySensitive()
        .accessibilityElement(children: .combine)
    }
}
