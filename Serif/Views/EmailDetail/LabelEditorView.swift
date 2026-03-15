import SwiftUI

struct LabelEditorView: View {
    let currentLabelIDs: [String]
    let allLabels: [GmailLabel]
    let detailVM: EmailDetailViewModel
    var onAddLabel: ((String) -> Void)?
    var onRemoveLabel: ((String) -> Void)?
    var onCreateAndAddLabel: ((String, @escaping (String?) -> Void) -> Void)?

    @State private var labelSearchText = ""
    @State private var isLabelFieldFocused = false
    @State private var highlightedIndex: Int = 0

    /// Comma-separated label IDs that the user has dismissed from suggestions.
    @AppStorage("dismissedLabelSuggestions") private var dismissedLabelSuggestionsRaw = ""

    /// The set of label IDs the user has dismissed so they are not re-shown.
    private var dismissedLabelSuggestions: Set<String> {
        Set(dismissedLabelSuggestionsRaw.split(separator: ",").map(String.init))
    }

    /// Records a label suggestion dismissal so it is excluded from future suggestions.
    func dismissSuggestion(labelID: String) {
        var ids = dismissedLabelSuggestions
        ids.insert(labelID)
        dismissedLabelSuggestionsRaw = ids.joined(separator: ",")
    }

    private func emailLabel(from gmailLabel: GmailLabel) -> EmailLabel {
        EmailLabel(
            id: GmailDataTransformer.deterministicUUID(from: gmailLabel.id),
            name: gmailLabel.displayName,
            color: gmailLabel.resolvedBgColor,
            textColor: gmailLabel.resolvedTextColor
        )
    }

    @State private var isAddingLabel = false

    /// Pre-computed label data to avoid redundant linear scans per render.
    private var precomputed: (
        currentUser: [GmailLabel],
        filtered: [GmailLabel],
        showCreate: Bool,
        items: [DropdownItem],
        shouldShowDropdown: Bool,
        query: String
    ) {
        let currentIDSet = Set(currentLabelIDs)
        let userLabels = allLabels.filter { !$0.isSystemLabel }
        let currentUser = userLabels.filter { currentIDSet.contains($0.id) }
        let query = labelSearchText.trimmingCharacters(in: .whitespaces)
        let queryLower = query.lowercased()
        let filtered: [GmailLabel] = queryLower.isEmpty
            ? []
            : userLabels.filter { $0.displayName.lowercased().contains(queryLower) }
        let showCreate = !query.isEmpty
            && !userLabels.contains { $0.displayName.caseInsensitiveCompare(query) == .orderedSame }
        var items: [DropdownItem] = filtered.map { .existing($0) }
        if showCreate { items.append(.create(query)) }
        let shouldShowDropdown = isLabelFieldFocused && !query.isEmpty
            && (!filtered.isEmpty || showCreate)
        return (currentUser, filtered, showCreate, items, shouldShowDropdown, query)
    }

    var body: some View {
        let data = precomputed

        HStack(spacing: 6) {
            ForEach(data.currentUser) { label in
                LabelChipView(label: emailLabel(from: label), isRemovable: true) {
                    let newIDs = currentLabelIDs.filter { $0 != label.id }
                    detailVM.updateLabelIDs(newIDs)
                    onRemoveLabel?(label.id)
                }
            }

            if isAddingLabel {
                HStack(spacing: 4) {
                    Image(systemName: "tag")
                        .font(Typography.captionSmallRegular)
                        .foregroundStyle(.tertiary)
                    TextField("Add label…", text: $labelSearchText, onEditingChanged: { editing in
                        isLabelFieldFocused = editing
                        if editing { highlightedIndex = 0 }
                        if !editing && labelSearchText.isEmpty {
                            isAddingLabel = false
                        }
                    })
                    .textFieldStyle(.plain)
                    .font(Typography.subheadRegular)
                    .foregroundStyle(.primary)
                    .onChange(of: labelSearchText) { _, _ in highlightedIndex = 0 }
                    .onSubmit { confirmHighlighted(items: data.items, showCreate: data.showCreate) }
                    .onKeyPress(.downArrow) {
                        highlightedIndex = min(highlightedIndex + 1, data.items.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlightedIndex = max(highlightedIndex - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        labelSearchText = ""
                        isAddingLabel = false
                        return .handled
                    }
                }
                .frame(minWidth: 80, maxWidth: 160)
                .overlay(alignment: .topLeading) {
                    if data.shouldShowDropdown {
                        autocompleteDropdown(items: data.items)
                            .offset(y: 24)
                    }
                }
            } else {
                Button {
                    isAddingLabel = true
                } label: {
                    Image(systemName: "plus")
                        .font(Typography.captionSmall)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .glassOrMaterial(in: .capsule, interactive: true)
                }
                .buttonStyle(.plain)
                .help("Add label")
            }

            Spacer()
        }
    }

    // MARK: - Dropdown

    private enum DropdownItem: Identifiable {
        case existing(GmailLabel)
        case create(String)

        var id: String {
            switch self {
            case .existing(let label): return label.id
            case .create(let name): return "create-\(name)"
            }
        }
    }

    private static let rowHeight: CGFloat = 38

    private func dropdownRow(_ item: DropdownItem, isHighlighted: Bool) -> some View {
        Button {
            switch item {
            case .existing(let label): addLabel(label)
            case .create: createNewLabel()
            }
        } label: {
            HStack(spacing: 8) {
                switch item {
                case .existing(let label):
                    Circle()
                        .fill(Color(hex: label.resolvedTextColor))
                        .frame(width: 10, height: 10)
                    Text(label.displayName)
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if currentLabelIDs.contains(label.id) {
                        Image(systemName: "checkmark")
                            .font(Typography.captionSmall)
                            .foregroundStyle(.tint)
                    }
                case .create(let name):
                    Image(systemName: "plus.circle.fill")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.tint)
                    Text("Create \"\(name)\"")
                        .font(Typography.subhead)
                        .foregroundStyle(.tint)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func autocompleteDropdown(items: [DropdownItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                                .background(Color(.separatorColor))
                                .padding(.leading, 28)
                        }

                        dropdownRow(item, isHighlighted: index == highlightedIndex)
                            .id(index)
                    }
                }
                .padding(4)
            }
            .scrollContentBackground(.hidden)
            .frame(width: 220, height: Self.rowHeight * min(CGFloat(items.count), 5) + 8)
            .onChange(of: highlightedIndex) { _, _ in
                if highlightedIndex < items.count {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(highlightedIndex, anchor: .center)
                    }
                }
            }
        }
        .dropdownPanelStyle()
    }

    private func confirmHighlighted(items: [DropdownItem], showCreate: Bool) {
        guard !items.isEmpty, highlightedIndex < items.count else {
            if showCreate { createNewLabel() }
            return
        }
        switch items[highlightedIndex] {
        case .existing(let label): addLabel(label)
        case .create: createNewLabel()
        }
    }

    private func addLabel(_ label: GmailLabel) {
        guard !currentLabelIDs.contains(label.id) else {
            labelSearchText = ""
            return
        }
        var newIDs = currentLabelIDs
        newIDs.append(label.id)
        detailVM.updateLabelIDs(newIDs)
        onAddLabel?(label.id)
        labelSearchText = ""
    }

    private func createNewLabel() {
        let name = labelSearchText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        labelSearchText = ""
        onCreateAndAddLabel?(name) { labelID in
            if let labelID {
                var newIDs = currentLabelIDs
                newIDs.append(labelID)
                detailVM.updateLabelIDs(newIDs)
            }
        }
    }
}
