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
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("Add label…", text: $labelSearchText, onEditingChanged: { editing in
                    isLabelFieldFocused = editing
                    if editing { highlightedIndex = 0 }
                })
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .onChange(of: labelSearchText) { _, _ in highlightedIndex = 0 }
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
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if currentLabelIDs.contains(label.id) {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                case .create(let name):
                    Image(systemName: "plus.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                    Text("Create \"\(name)\"")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var autocompleteDropdown: some View {
        let items = dropdownItems
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
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
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
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
