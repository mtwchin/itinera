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

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Section.allCases) { section in
                                Button {
                                    withAnimation(.snappy) { selectedSection = section }
                                } label: {
                                    Text(section.rawValue)
                                        .font(.subheadline.weight(selectedSection == section ? .semibold : .regular))
                                        .foregroundStyle(selectedSection == section ? .white : theme.primaryText)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(
                                            selectedSection == section
                                                ? theme.accent
                                                : theme.accent.opacity(0.09),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    .sensoryFeedback(.selection, trigger: selectedSection)

                    if isLoading {
                        ForEach(0..<4, id: \.self) { i in
                            ItineraSkeletonRow()
                                .opacity(1 - Double(i) * 0.15)
                        }
                    } else {
                        VStack(alignment: .leading) {
                            switch selectedSection {
                            case .essentials: essentialsSection
                            case .checklist: checklistSection
                            case .expenses: expensesSection
                            case .people: peopleSection
                            }
                        }
                        .id(selectedSection)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                    }
                }
                .padding(18)
                .padding(.bottom, 28)
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
                .buttonStyle(ItineraPrimaryButtonStyle())

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
                .revealOnAppear()
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
                            .font(.headline)
                            .foregroundStyle(theme.accentContrast)
                            .frame(width: 44, height: 44)
                            .background(theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(checklistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(checklistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)
                }
            }

            if checklist.isEmpty {
                emptyCard("No checklist items yet", icon: "checklist")
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
                                .scaleEffect(item.isCompleted ? 1.08 : 1)
                                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: item.isCompleted)
                        }
                        .buttonStyle(.plain)
                        .sensoryFeedback(item.isCompleted ? .selection : .success, trigger: item.isCompleted)
                        Text(item.title)
                            .foregroundStyle(item.isCompleted ? theme.secondaryText : theme.primaryText)
                            .strikethrough(item.isCompleted, color: theme.secondaryText)
                            .animation(.easeInOut(duration: 0.2), value: item.isCompleted)
                        Spacer()
                        if !item.isCompleted {
                            Button(role: .destructive) {
                                Task { await deleteChecklistItem(item) }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(theme.danger.opacity(0.7))
                            }
                        }
                    }
                }
                .opacity(item.isCompleted ? 0.65 : 1)
                .animation(.easeInOut(duration: 0.25), value: item.isCompleted)
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
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(theme.success)
                            .frame(width: 38, height: 38)
                            .background(theme.success.opacity(0.12), in: Circle())
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
                .revealOnAppear()
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
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Invite ready")
                                .font(.headline)
                                .foregroundStyle(theme.primaryText)
                            Spacer()
                            Label("Expires \(latestInvite.expiresAt)", systemImage: "clock.badge.exclamationmark")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(theme.warning)
                        }
                        ShareLink(item: "itinera://invite/\(latestInvite.token)") {
                            Label("Share private invite", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(ItineraPrimaryButtonStyle())
                    }
                }
            }

            if !collaborators.isEmpty {
                ForEach(collaborators) { collaborator in
                    ItineraSurface(padding: 14) {
                        HStack(spacing: 12) {
                            let isEditor = collaborator.role == "editor"
                            Image(systemName: isEditor ? "pencil.circle.fill" : "eye.circle.fill")
                                .font(.title3)
                                .foregroundStyle(isEditor ? theme.accent : theme.route)
                                .frame(width: 38, height: 38)
                                .background(
                                    (isEditor ? theme.accent : theme.route).opacity(0.10),
                                    in: Circle()
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(collaborator.role.capitalized)
                                    .font(.headline)
                                    .foregroundStyle(theme.primaryText)
                                Text(isEditor ? "Can edit this trip" : "View-only access")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await removeCollaborator(collaborator) }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(theme.danger.opacity(0.7))
                            }
                            .accessibilityLabel("Remove \(collaborator.role) access")
                        }
                    }
                    .revealOnAppear()
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
                    Button {
                        Task { await acceptInvite() }
                    } label: {
                        Label("Join trip", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(ItineraPrimaryButtonStyle())
                    .disabled(inviteToken.count < 32)
                    .opacity(inviteToken.count < 32 ? 0.48 : 1)
                }
            }
        }
    }

    private func emptyCard(_ message: String, icon: String) -> some View {
        ItineraSurface {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(theme.route.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .background(theme.route.opacity(0.08), in: Circle())
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(theme.primaryText.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
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
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedReservations = appState.apiClient.reservations(jobID)
            async let loadedChecklist = appState.apiClient.checklist(jobID)
            async let loadedExpenses = appState.apiClient.expenses(jobID)
            async let loadedCollaborators = appState.apiClient.collaborators(jobID)
            (reservations, checklist, expenses, collaborators) = try await (
                loadedReservations,
                loadedChecklist,
                loadedExpenses,
                loadedCollaborators
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createReservation() async {
        do {
            let created = try await appState.apiClient.createReservation(
                jobID,
                input: reservationDraft.input
            )
            reservations.append(created)
            reservationDraft = ReservationDraft()
            isShowingReservationForm = false
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteReservation(_ reservation: TripReservation) async {
        do {
            try await appState.apiClient.deleteReservation(jobID, reservationID: reservation.id)
            reservations.removeAll { $0.id == reservation.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private func addChecklistItem() async {
        let title = checklistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let created = try await appState.apiClient.createChecklistItem(
                jobID,
                input: TripChecklistItemCreate(title: title, position: checklist.count)
            )
            checklist.append(created)
            checklistTitle = ""
        } catch { errorMessage = error.localizedDescription }
    }

    private func toggleChecklistItem(_ item: TripChecklistItem) async {
        do {
            let updated = try await appState.apiClient.updateChecklistItem(
                jobID,
                itemID: item.id,
                input: TripChecklistItemUpdate(isCompleted: !item.isCompleted)
            )
            if let index = checklist.firstIndex(where: { $0.id == item.id }) {
                checklist[index] = updated
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteChecklistItem(_ item: TripChecklistItem) async {
        do {
            try await appState.apiClient.deleteChecklistItem(jobID, itemID: item.id)
            checklist.removeAll { $0.id == item.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private func createExpense(_ input: TripExpenseCreate) async {
        do {
            expenses.append(try await appState.apiClient.createExpense(jobID, input: input))
            isShowingExpenseForm = false
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteExpense(_ expense: TripExpense) async {
        do {
            try await appState.apiClient.deleteExpense(jobID, expenseID: expense.id)
            expenses.removeAll { $0.id == expense.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private func createInvite(email: String?, role: String) async {
        do {
            latestInvite = try await appState.apiClient.createCollaborationInvite(
                jobID,
                input: CollaborationInviteCreate(email: email, role: role, expiresInHours: 72)
            )
            isShowingInviteForm = false
        } catch { errorMessage = error.localizedDescription }
    }

    private func removeCollaborator(_ collaborator: TripCollaborator) async {
        do {
            try await appState.apiClient.removeCollaborator(jobID, collaboratorID: collaborator.id)
            collaborators.removeAll { $0.id == collaborator.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private func acceptInvite() async {
        do {
            _ = try await appState.apiClient.acceptCollaborationInvite(token: inviteToken)
            inviteToken = ""
            appState.markLibraryChanged()
        } catch { errorMessage = error.localizedDescription }
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
        ZStack {
            ItineraBackground()
            ScrollView {
                VStack(spacing: 18) {
                    ItineraSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            ItineraSectionHeading(number: "01", title: "Reservation details", message: nil)

                            TextField("Title", text: $draft.title)
                                .itineraField()

                            TextField("Confirmation code", text: $draft.confirmationCode)
                                .textInputAutocapitalization(.characters)
                                .itineraField()

                            TextField("Address", text: $draft.address)
                                .itineraField()

                            TextField("Reservation URL", text: $draft.url)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .itineraField()

                            TextField("Notes", text: $draft.notes, axis: .vertical)
                                .lineLimit(3...6)
                                .itineraField()
                        }
                    }

                    ItineraSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            ItineraSectionHeading(number: "02", title: "Timing", message: nil)

                            Toggle("Include date and time", isOn: $draft.includesTime)
                                .tint(theme.accent)

                            if draft.includesTime {
                                HStack {
                                    Text("Starts")
                                        .font(.subheadline)
                                        .foregroundStyle(theme.primaryText)
                                    Spacer()
                                    DatePicker("Starts", selection: $draft.startsAt)
                                        .labelsHidden()
                                        .tint(theme.accent)
                                }
                                HStack {
                                    Text("Ends")
                                        .font(.subheadline)
                                        .foregroundStyle(theme.primaryText)
                                    Spacer()
                                    DatePicker("Ends", selection: $draft.endsAt, in: draft.startsAt...)
                                        .labelsHidden()
                                        .tint(theme.accent)
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Review reservation")
        .navigationBarTitleDisplayMode(.inline)
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
        ZStack {
            ItineraBackground()
            ScrollView {
                VStack(spacing: 18) {
                    ItineraSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            ItineraSectionHeading(number: "01", title: "Expense details", message: nil)

                            TextField("Title", text: $title)
                                .itineraField()

                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Amount")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(theme.secondaryText)
                                    TextField("0.00", text: $amount)
                                        .keyboardType(.decimalPad)
                                        .itineraField()
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Currency")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(theme.secondaryText)
                                    TextField("USD", text: $currency)
                                        .textInputAutocapitalization(.characters)
                                        .itineraField()
                                }
                            }

                            TextField("Category (optional)", text: $category)
                                .itineraField()

                            TextField("Paid by (optional)", text: $paidBy)
                                .itineraField()

                            TextField("Notes (optional)", text: $notes, axis: .vertical)
                                .lineLimit(2...5)
                                .itineraField()
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Add expense")
        .navigationBarTitleDisplayMode(.inline)
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
    @Environment(\.itineraTheme) private var theme
    @State private var email = ""
    @State private var role = "viewer"
    let onCreate: (String?, String) -> Void

    var body: some View {
        ZStack {
            ItineraBackground()
            ScrollView {
                VStack(spacing: 18) {
                    ItineraSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            ItineraSectionHeading(number: "01", title: "Invite details", message: nil)

                            TextField("Email (optional)", text: $email)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .itineraField()
                                .accessibilityLabel("Email address (optional)")

                            VStack(alignment: .leading, spacing: 9) {
                                Text("Permission")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.secondaryText)
                                HStack(spacing: 8) {
                                    ForEach([("viewer", "Can view"), ("editor", "Can edit")], id: \.0) { roleValue, roleLabel in
                                        Button {
                                            withAnimation(.snappy) { role = roleValue }
                                        } label: {
                                            Text(roleLabel)
                                                .font(.subheadline.weight(role == roleValue ? .semibold : .regular))
                                                .foregroundStyle(role == roleValue ? .white : theme.primaryText)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 8)
                                                .background(
                                                    role == roleValue ? theme.accent : theme.accent.opacity(0.09),
                                                    in: Capsule()
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(roleLabel)
                                        .accessibilityAddTraits(role == roleValue ? .isSelected : [])
                                    }
                                }
                                .sensoryFeedback(.selection, trigger: role)
                            }
                        }
                    }
                }
                .padding(18)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Invite tripmate")
        .navigationBarTitleDisplayMode(.inline)
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
