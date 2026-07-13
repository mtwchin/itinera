import SwiftUI
import UniformTypeIdentifiers

struct TripToolsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case essentials = "Essentials"
        case checklist = "Checklist"
        case expenses = "Expenses"
        case people = "People"

        var id: String { rawValue }
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.itineraTheme) private var theme
    @Environment(\.privateAppSession) private var privateAppSession

    let jobID: String
    let tripTitle: String

    @State private var selectedSection: Section = .essentials
    @State private var reservations: [TripReservation] = []
    @State private var checklist: [TripChecklistItem] = []
    @State private var expenses: [TripExpense] = []
    @State private var collaborators: [TripCollaborator] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingReservationForm = false
    @State private var reservationDraft = ReservationDraft()
    @State private var isImportingReservation = false
    @State private var checklistTitle = ""
    @State private var isShowingExpenseForm = false
    @State private var isShowingInviteForm = false
    @State private var latestInvite: CollaborationInvite?
    @State private var inviteToken = ""

    var body: some View {
        ZStack {
            ItineraBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ItineraBrandHeader(
                        eyebrow: "Trip field kit",
                        title: tripTitle,
                        message: "Keep confirmations, preparation, shared costs, and travel companions together."
                    )

                    if let errorMessage {
                        ItineraStatusBanner(message: errorMessage, kind: .warning)
                    }

                    Picker("Trip tools", selection: $selectedSection) {
                        ForEach(Section.allCases) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch selectedSection {
                    case .essentials: essentialsSection
                    case .checklist: checklistSection
                    case .expenses: expensesSection
                    case .people: peopleSection
                    }
                }
                .padding(18)
                .padding(.bottom, 28)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.route)
            }
        }
        .navigationTitle("Trip tools")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $isShowingReservationForm) {
            NavigationStack {
                ReservationFormView(draft: $reservationDraft) {
                    Task { await createReservation() }
                }
            }
            .environment(\.itineraTheme, theme)
        }
        .sheet(isPresented: $isShowingExpenseForm) {
            NavigationStack {
                ExpenseFormView { input in
                    Task { await createExpense(input) }
                }
            }
            .environment(\.itineraTheme, theme)
        }
        .sheet(isPresented: $isShowingInviteForm) {
            NavigationStack {
                InviteFormView { email, role in
                    Task { await createInvite(email: email, role: role) }
                }
            }
            .environment(\.itineraTheme, theme)
        }
        .fileImporter(
            isPresented: $isImportingReservation,
            allowedContentTypes: [.pdf, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            handleReservationImport(result)
        }
    }

    private var essentialsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ItineraSectionHeading(
                number: "RESERVATIONS",
                title: "Critical details",
                message: "Review imported information before it is saved."
            )

            HStack(spacing: 10) {
                Button {
                    reservationDraft = ReservationDraft()
                    isShowingReservationForm = true
                } label: {
                    Label("Add manually", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)

                Button {
                    isImportingReservation = true
                } label: {
                    Label("Import file", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(theme.accent)
            }

            if reservations.isEmpty {
                emptyCard("No reservations yet", icon: "ticket")
            }

            ForEach(reservations) { reservation in
                ItineraSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(reservation.title)
                                .font(.headline)
                                .foregroundStyle(theme.primaryText)
                            Spacer()
                            Button(role: .destructive) {
                                Task { await deleteReservation(reservation) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete \(reservation.title)")
                        }
                        if let confirmationCode = reservation.confirmationCode {
                            Label("Confirmation \(confirmationCode)", systemImage: "number")
                                .font(.subheadline.monospaced())
                        }
                        if let startsAt = reservation.startsAt {
                            Label(startsAt, systemImage: "calendar")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(theme.secondaryText)
                        }
                        if let address = reservation.address {
                            Label(address, systemImage: "mappin")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                        if let url = reservation.url, let destination = URL(string: url) {
                            Link("Open reservation", destination: destination)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        }
    }

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ItineraSectionHeading(
                number: "PREP",
                title: "Packing & preparation",
                message: "Small tasks stay visible until they're done."
            )

            ItineraSurface {
                HStack(spacing: 10) {
                    TextField("Add a checklist item", text: $checklistTitle)
                        .itineraField()
                    Button {
                        Task { await addChecklistItem() }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .disabled(checklistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            ForEach(checklist.sorted { $0.position < $1.position }) { item in
                ItineraSurface(padding: 14) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await toggleChecklistItem(item) }
                        } label: {
                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(item.isCompleted ? theme.success : theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        Text(item.title)
                            .foregroundStyle(theme.primaryText)
                            .strikethrough(item.isCompleted)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await deleteChecklistItem(item) }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }

    private var expensesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ItineraSectionHeading(
                number: "BUDGET",
                title: "Shared expenses",
                message: expenseSummary
            )

            Button {
                isShowingExpenseForm = true
            } label: {
                Label("Add expense", systemImage: "plus")
            }
            .buttonStyle(ItineraPrimaryButtonStyle())

            if expenses.isEmpty {
                emptyCard("No expenses yet", icon: "banknote")
            }

            ForEach(expenses) { expense in
                ItineraSurface(padding: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "banknote.fill")
                            .foregroundStyle(theme.route)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(expense.title)
                                .font(.headline)
                                .foregroundStyle(theme.primaryText)
                            Text(expenseAmount(expense))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(theme.secondaryText)
                            if let paidBy = expense.paidBy {
                                Text("Paid by \(paidBy)")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await deleteExpense(expense) }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ItineraSectionHeading(
                number: "PEOPLE",
                title: "Travel together",
                message: "Invite a viewer or editor with an expiring private link."
            )

            Button {
                isShowingInviteForm = true
            } label: {
                Label("Invite a tripmate", systemImage: "person.badge.plus")
            }
            .buttonStyle(ItineraPrimaryButtonStyle())

            if let latestInvite {
                ItineraSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Invite ready")
                            .font(.headline)
                        Text("This link expires at \(latestInvite.expiresAt).")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                        ShareLink(item: "itinera://invite/\(latestInvite.token)") {
                            Label("Share private invite", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }

            if !collaborators.isEmpty {
                ForEach(collaborators) { collaborator in
                    ItineraSurface(padding: 14) {
                        HStack {
                            Label(collaborator.role.capitalized, systemImage: "person.crop.circle")
                                .foregroundStyle(theme.primaryText)
                            Spacer()
                            Button(role: .destructive) {
                                Task { await removeCollaborator(collaborator) }
                            } label: {
                                Text("Remove")
                            }
                        }
                    }
                }
            }

            ItineraSurface {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Have an invite?")
                        .font(.headline)
                    TextField("Paste invite token", text: $inviteToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .itineraField()
                    Button("Join trip") {
                        Task { await acceptInvite() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(inviteToken.count < 32)
                }
            }
        }
    }

    private func emptyCard(_ message: String, icon: String) -> some View {
        ItineraSurface {
            Label(message, systemImage: icon)
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
    }

    private var expenseSummary: String {
        let grouped = Dictionary(grouping: expenses, by: \.currency)
        guard !grouped.isEmpty else { return "Track costs without losing the original currency." }
        return grouped.keys.sorted().map { currency in
            let total = grouped[currency, default: []].reduce(Int64(0)) { $0 + $1.amountMinor }
            return "\(currency) \(Decimal(total) / 100)"
        }.joined(separator: " · ")
    }

    private func expenseAmount(_ expense: TripExpense) -> String {
        let amount = Decimal(expense.amountMinor) / 100
        return "\(expense.currency) \(amount)"
    }

    private func load() async {
        guard let session = privateAppSession else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await scopedRequest(session: session, { client in
                async let loadedReservations = client.reservations(jobID)
                async let loadedChecklist = client.checklist(jobID)
                async let loadedExpenses = client.expenses(jobID)
                async let loadedCollaborators = client.collaborators(jobID)
                return try await TripToolsSnapshot(
                    reservations: loadedReservations,
                    checklist: loadedChecklist,
                    expenses: loadedExpenses,
                    collaborators: loadedCollaborators
                )
            }) { snapshot in
                reservations = snapshot.reservations
                checklist = snapshot.checklist
                expenses = snapshot.expenses
                collaborators = snapshot.collaborators
                errorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func createReservation() async {
        guard let session = privateAppSession else { return }
        do {
            let input = reservationDraft.input
            try await scopedRequest(session: session, { client in
                try await client.createReservation(jobID, input: input)
            }) { created in
                reservations.append(created)
                reservationDraft = ReservationDraft()
                isShowingReservationForm = false
            }
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func deleteReservation(_ reservation: TripReservation) async {
        guard let session = privateAppSession else { return }
        do {
            try await scopedRequest(session: session, { client in
                try await client.deleteReservation(
                    jobID,
                    reservationID: reservation.id
                )
            }) { _ in
                reservations.removeAll { $0.id == reservation.id }
            }
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func addChecklistItem() async {
        guard let session = privateAppSession else { return }
        let title = checklistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let input = TripChecklistItemCreate(
                title: title,
                position: checklist.count
            )
            try await scopedRequest(session: session, { client in
                try await client.createChecklistItem(jobID, input: input)
            }) { created in
                checklist.append(created)
                checklistTitle = ""
            }
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func toggleChecklistItem(_ item: TripChecklistItem) async {
        guard let session = privateAppSession else { return }
        do {
            let input = TripChecklistItemUpdate(
                isCompleted: !item.isCompleted
            )
            try await scopedRequest(session: session, { client in
                try await client.updateChecklistItem(
                    jobID,
                    itemID: item.id,
                    input: input
                )
            }) { updated in
                if let index = checklist.firstIndex(where: { $0.id == item.id }) {
                    checklist[index] = updated
                }
            }
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func deleteChecklistItem(_ item: TripChecklistItem) async {
        guard let session = privateAppSession else { return }
        do {
            try await scopedRequest(session: session, { client in
                try await client.deleteChecklistItem(jobID, itemID: item.id)
            }) { _ in
                checklist.removeAll { $0.id == item.id }
            }
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func createExpense(_ input: TripExpenseCreate) async {
        guard let session = privateAppSession else { return }
        do {
            try await scopedRequest(session: session, { client in
                try await client.createExpense(jobID, input: input)
            }) { created in
                expenses.append(created)
                isShowingExpenseForm = false
            }
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func deleteExpense(_ expense: TripExpense) async {
        guard let session = privateAppSession else { return }
        do {
            try await scopedRequest(session: session, { client in
                try await client.deleteExpense(jobID, expenseID: expense.id)
            }) { _ in
                expenses.removeAll { $0.id == expense.id }
            }
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func createInvite(email: String?, role: String) async {
        guard let session = privateAppSession else { return }
        do {
            let input = CollaborationInviteCreate(
                email: email,
                role: role,
                expiresInHours: 72
            )
            try await scopedRequest(session: session, { client in
                try await client.createCollaborationInvite(jobID, input: input)
            }) { invite in
                latestInvite = invite
                isShowingInviteForm = false
            }
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func removeCollaborator(_ collaborator: TripCollaborator) async {
        guard let session = privateAppSession else { return }
        do {
            try await scopedRequest(session: session, { client in
                try await client.removeCollaborator(
                    jobID,
                    collaboratorID: collaborator.id
                )
            }) { _ in
                collaborators.removeAll { $0.id == collaborator.id }
            }
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func acceptInvite() async {
        guard let session = privateAppSession else { return }
        do {
            let token = inviteToken
            try await scopedRequest(session: session, { client in
                try await client.acceptCollaborationInvite(token: token)
            }) { _ in
                inviteToken = ""
                appState.markLibraryChanged(session: session)
            }
        } catch {
            guard await appState.isCurrent(session) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func scopedRequest<Value: Sendable>(
        session: PrivateAppSession,
        _ operation: @escaping @Sendable (IdentityBoundAPIClient) async throws -> Value,
        apply: (Value) -> Void
    ) async throws {
        let scopedValue = try await appState.scopedAPIValue(
            session: session,
            operation
        )
        guard await appState.consume(scopedValue, perform: apply) else {
            throw IdentityCoordinatorError.staleIdentity
        }
    }

    private func handleReservationImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            reservationDraft = ReservationDraft(
                title: url.deletingPathExtension().lastPathComponent,
                notes: "Imported from \(url.lastPathComponent). Review and add the important confirmation details before saving."
            )
            isShowingReservationForm = true
        } catch {
            errorMessage = "That reservation file couldn't be opened."
        }
    }
}

private struct TripToolsSnapshot: Sendable {
    let reservations: [TripReservation]
    let checklist: [TripChecklistItem]
    let expenses: [TripExpense]
    let collaborators: [TripCollaborator]
}

private struct ReservationDraft {
    var title = ""
    var confirmationCode = ""
    var address = ""
    var url = ""
    var notes = ""
    var includesTime = false
    var startsAt = Date()
    var endsAt = Date().addingTimeInterval(60 * 60)

    var input: TripReservationCreate {
        let formatter = ISO8601DateFormatter()
        return TripReservationCreate(
            title: title,
            confirmationCode: confirmationCode.nilIfBlank,
            startsAt: includesTime ? formatter.string(from: startsAt) : nil,
            endsAt: includesTime ? formatter.string(from: endsAt) : nil,
            address: address.nilIfBlank,
            url: url.nilIfBlank,
            notes: notes.nilIfBlank
        )
    }
}

private struct ReservationFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme
    @Binding var draft: ReservationDraft
    let onSave: () -> Void

    var body: some View {
        Form {
            Section("Reservation") {
                TextField("Title", text: $draft.title)
                TextField("Confirmation code", text: $draft.confirmationCode)
                    .textInputAutocapitalization(.characters)
                TextField("Address", text: $draft.address)
                TextField("Reservation URL", text: $draft.url)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...6)
            }
            Section("Timing") {
                Toggle("Include date and time", isOn: $draft.includesTime)
                if draft.includesTime {
                    DatePicker("Starts", selection: $draft.startsAt)
                    DatePicker("Ends", selection: $draft.endsAt, in: draft.startsAt...)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ItineraBackground())
        .navigationTitle("Review reservation")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: onSave)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .tint(theme.accent)
    }
}

private struct ExpenseFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.itineraTheme) private var theme
    @State private var title = ""
    @State private var amount = ""
    @State private var currency = Locale.current.currency?.identifier ?? "USD"
    @State private var category = ""
    @State private var paidBy = ""
    @State private var notes = ""
    let onSave: (TripExpenseCreate) -> Void

    var body: some View {
        Form {
            Section("Expense") {
                TextField("Title", text: $title)
                TextField("Amount", text: $amount)
                    .keyboardType(.decimalPad)
                TextField("Currency (USD)", text: $currency)
                    .textInputAutocapitalization(.characters)
                TextField("Category", text: $category)
                TextField("Paid by", text: $paidBy)
                TextField("Notes", text: $notes, axis: .vertical)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ItineraBackground())
        .navigationTitle("Add expense")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let decimal = Decimal(string: amount) else { return }
                    let minor = NSDecimalNumber(decimal: decimal * 100).int64Value
                    onSave(
                        TripExpenseCreate(
                            title: title,
                            amountMinor: minor,
                            currency: currency.uppercased(),
                            category: category.nilIfBlank,
                            paidBy: paidBy.nilIfBlank,
                            notes: notes.nilIfBlank
                        )
                    )
                }
                .disabled(!isValid)
            }
        }
        .tint(theme.accent)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Decimal(string: amount) != nil
            && currency.count == 3
    }
}

private struct InviteFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role = "viewer"
    let onCreate: (String?, String) -> Void

    var body: some View {
        Form {
            Section("Private invite") {
                TextField("Email (optional)", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                Picker("Permission", selection: $role) {
                    Text("Can view").tag("viewer")
                    Text("Can edit").tag("editor")
                }
            }
        }
        .navigationTitle("Invite tripmate")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create invite") { onCreate(email.nilIfBlank, role) }
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
