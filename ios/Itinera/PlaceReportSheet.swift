import SwiftUI

struct PlaceReportSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme

    let jobID: String
    let activity: Activity
    let onSubmitted: () -> Void

    @State private var category = "incorrect_details"
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var submitted = false

    var body: some View {
        Form {
            Section {
                Text(activity.name)
                    .font(.headline)
                Text(activity.address)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Section("What's wrong?") {
                Picker("Issue", selection: $category) {
                    Text("Place is closed").tag("closed")
                    Text("Incorrect details").tag("incorrect_details")
                    Text("Safety concern").tag("unsafe")
                    Text("Duplicate stop").tag("duplicate")
                    Text("Something else").tag("other")
                }
                TextField("Optional details", text: $details, axis: .vertical)
                    .lineLimit(3...7)
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(theme.danger)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ItineraBackground())
        .navigationTitle("Report place")
        .sensoryFeedback(.success, trigger: submitted)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView().tint(theme.route)
                    } else {
                        Text("Submit")
                    }
                }
                .disabled(isSubmitting)
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await appState.apiClient.createPlaceReport(
                jobID,
                input: PlaceReportCreate(
                    activityName: activity.name,
                    category: category,
                    details: details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : details
                )
            )
            onSubmitted()
            submitted = true
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
