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
    @Environment(\.theme) private var theme

    private var currentUserLabels: [GmailLabel] {
        let ids = Set(currentLabelIDs)
        return allLabels.filter { !$0.isSystemLabel && ids.contains($0.id) }
    }

    private var availableUserLabels: [GmailLabel] {
        allLabels.filter { !$0.isSystemLabel }
    }

    private func emailLabel(from gmailLabel: GmailLabel) -> EmailLabel {
        EmailLabel(
            id: GmailDataTransformer.deterministicUUID(from: gmailLabel.id),
            name: gmailLabel.displayName,
            color: gmailLabel.resolvedBgColor,
            textColor: gmailLabel.resolvedTextColor
        )
    }

    private var showDropdown: Bool {
        isLabelFieldFocused && !labelSearchText.trimmingCharacters(in: .whitespaces).isEmpty
            && (!filteredLabels.isEmpty || showCreateOption)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(currentUserLabels) { label in
                LabelChipView(label: emailLabel(from: label), isRemovable: true) {
                    let newIDs = currentLabelIDs.filter { $0 != label.id }
                    detailVM.updateLabelIDs(newIDs)
                    onRemoveLabel?(label.id)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.system(size: 10))
                    .foregroundColor(theme.textTertiary)
                TextField("Add label…", text: $labelSearchText, onEditingChanged: { editing in
                    isLabelFieldFocused = editing
                    if editing { highlightedIndex = 0 }
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.textPrimary)
                .onChange(of: labelSearchText) { _ in highlightedIndex = 0 }
                .onSubmit { confirmHighlighted() }
                .onKeyPress(.downArrow) {
                    highlightedIndex = min(highlightedIndex + 1, dropdownItems.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlightedIndex = max(highlightedIndex - 1, 0)
                    return .handled
                }
            }
            .frame(minWidth: 80, maxWidth: 160)
            .overlay(alignment: .topLeading) {
                if showDropdown {
                    autocompleteDropdown
                        .offset(y: 24)
                }
            }

            Spacer()
        }
    }

    // MARK: - Dropdown

    private enum DropdownItem {
        case existing(GmailLabel)
        case create(String)
    }

    private var dropdownItems: [DropdownItem] {
        var items: [DropdownItem] = filteredLabels.map { .existing($0) }
        if showCreateOption { items.append(.create(labelSearchText.trimmingCharacters(in: .whitespaces))) }
        return items
    }

    private var autocompleteDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            let items = dropdownItems
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let isHighlighted = index == highlightedIndex
                Button {
                    switch item {
                    case .existing(let label): addLabel(label)
                    case .create: createNewLabel()
                    }
                } label: {
                    Group {
                        switch item {
                        case .existing(let label):
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(hex: label.resolvedBgColor))
                                    .frame(width: 8, height: 8)
                                Text(label.displayName)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.textPrimary)
                                if currentLabelIDs.contains(label.id) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(theme.accentPrimary)
                                }
                            }
                        case .create(let name):
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.accentPrimary)
                                Text("Create \"\(name)\"")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.accentPrimary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isHighlighted ? theme.hoverBackground : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .background(theme.cardBackground.opacity(0.95))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    private func confirmHighlighted() {
        let items = dropdownItems
        guard !items.isEmpty, highlightedIndex < items.count else {
            if showCreateOption { createNewLabel() }
            return
        }
        switch items[highlightedIndex] {
        case .existing(let label): addLabel(label)
        case .create: createNewLabel()
        }
    }

    private var filteredLabels: [GmailLabel] {
        let query = labelSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return availableUserLabels.filter { $0.displayName.lowercased().contains(query) }
    }

    private var showCreateOption: Bool {
        let query = labelSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return false }
        return !availableUserLabels.contains { $0.displayName.caseInsensitiveCompare(query) == .orderedSame }
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
