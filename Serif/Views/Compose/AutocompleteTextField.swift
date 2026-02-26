import SwiftUI

struct AutocompleteTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let contacts: [StoredContact]

    @State private var isFocused = false
    @State private var highlightedIndex = 0
    @Environment(\.theme) private var theme

    private var currentSegment: String {
        let parts = text.components(separatedBy: ",")
        return (parts.last ?? "").trimmingCharacters(in: .whitespaces)
    }

    private var suggestions: [StoredContact] {
        let query = currentSegment.lowercased()
        guard query.count >= 3 else { return [] }
        return Array(contacts.filter {
            $0.name.lowercased().contains(query) || $0.email.lowercased().contains(query)
        }.prefix(5))
    }

    private var showDropdown: Bool {
        isFocused && !suggestions.isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.textTertiary)
                .frame(width: 50, alignment: .leading)

            TextField(placeholder, text: $text, onEditingChanged: { editing in
                isFocused = editing
                if editing { highlightedIndex = 0 }
            })
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(theme.textPrimary)
            .onChange(of: text) { _ in highlightedIndex = 0 }
            .onKeyPress(.return) {
                guard showDropdown, highlightedIndex < suggestions.count else { return .ignored }
                selectContact(suggestions[highlightedIndex])
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard showDropdown else { return .ignored }
                highlightedIndex = min(highlightedIndex + 1, suggestions.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard showDropdown else { return .ignored }
                highlightedIndex = max(highlightedIndex - 1, 0)
                return .handled
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .overlay(alignment: .topLeading) {
            if showDropdown {
                autocompleteDropdown
                    .offset(x: 74, y: 38)
            }
        }
        .zIndex(10)
    }

    private var autocompleteDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, contact in
                let isHighlighted = index == highlightedIndex
                Button {
                    selectContact(contact)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            if !contact.name.isEmpty {
                                Text(contact.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.textPrimary)
                            }
                            Text(contact.email)
                                .font(.system(size: 11))
                                .foregroundColor(theme.textSecondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isHighlighted ? theme.accentPrimary.opacity(0.25) : Color.clear)
                    )
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
        guard showDropdown, highlightedIndex < suggestions.count else { return }
        selectContact(suggestions[highlightedIndex])
    }

    private func selectContact(_ contact: StoredContact) {
        var parts = text.components(separatedBy: ",")
        if !parts.isEmpty { parts.removeLast() }
        parts.append(" \(contact.email)")
        text = parts.joined(separator: ",") + ", "
        if text.hasPrefix(" ") { text = String(text.dropFirst()) }
    }
}
