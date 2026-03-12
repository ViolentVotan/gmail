import SwiftUI

struct FiltersSettingsView: View {
    let accountID: String
    @State private var filters: [GmailFilter] = []
    @State private var isLoading = false
    @State private var showEditor = false
    @State private var filterToDelete: GmailFilter?

    var body: some View {
        VStack {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filters.isEmpty {
                ContentUnavailableView(
                    "No Filters",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Create filters to automatically organize incoming mail.")
                )
            } else {
                List {
                    ForEach(filters) { filter in
                        filterRow(filter)
                    }
                }
            }
        }
        .toolbar {
            Button { showEditor = true } label: { Label("Create Filter", systemImage: "plus") }
        }
        .sheet(isPresented: $showEditor) {
            FilterEditorView(accountID: accountID) { _ in Task { await loadFilters() } }
        }
        .alert("Delete Filter", isPresented: Binding(
            get: { filterToDelete != nil },
            set: { if !$0 { filterToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { filterToDelete = nil }
            Button("Delete", role: .destructive) {
                if let filter = filterToDelete {
                    Task {
                        try? await GmailFilterService.shared.deleteFilter(id: filter.id, accountID: accountID)
                        await loadFilters()
                    }
                }
                filterToDelete = nil
            }
        }
        .task { await loadFilters() }
    }

    private func filterRow(_ filter: GmailFilter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(filterSummary(filter)).font(.subheadline)
            Text(actionSummary(filter)).font(.caption).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Delete", role: .destructive) { filterToDelete = filter }
        }
    }

    private func loadFilters() async {
        isLoading = true
        defer { isLoading = false }
        filters = (try? await GmailFilterService.shared.listFilters(accountID: accountID)) ?? []
    }

    private func filterSummary(_ filter: GmailFilter) -> String {
        var parts: [String] = []
        if let from = filter.criteria?.from { parts.append("From: \(from)") }
        if let to = filter.criteria?.to { parts.append("To: \(to)") }
        if let subject = filter.criteria?.subject { parts.append("Subject: \(subject)") }
        if let query = filter.criteria?.query { parts.append("Contains: \(query)") }
        return parts.isEmpty ? "No criteria" : parts.joined(separator: ", ")
    }

    private func actionSummary(_ filter: GmailFilter) -> String {
        var parts: [String] = []
        if let add = filter.action?.addLabelIds, !add.isEmpty { parts.append("Add labels: \(add.joined(separator: ", "))") }
        if let remove = filter.action?.removeLabelIds {
            if remove.contains("INBOX") { parts.append("Archive") }
            if remove.contains("UNREAD") { parts.append("Mark read") }
        }
        return parts.isEmpty ? "No action" : parts.joined(separator: ", ")
    }
}
