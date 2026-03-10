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
        return contacts.filter {
            $0.name.lowercased().contains(query) || $0.email.lowercased().contains(query)
        }
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

    private func contactInitials(_ contact: StoredContact) -> String {
        if !contact.name.isEmpty {
            let parts = contact.name.split(separator: " ")
            let first = parts.first?.prefix(1) ?? ""
            let last = parts.count > 1 ? parts.last!.prefix(1) : ""
            return "\(first)\(last)".uppercased()
        }
        return String(contact.email.prefix(1)).uppercased()
    }

    private func contactColor(_ contact: StoredContact) -> String {
        let colors = ["#4285F4", "#EA4335", "#FBBC04", "#34A853", "#FF6D01", "#46BDC6", "#7B1FA2", "#C2185B"]
        let hash = abs(contact.email.hashValue)
        return colors[hash % colors.count]
    }

    private func contactRow(_ contact: StoredContact, isHighlighted: Bool) -> some View {
        Button {
            selectContact(contact)
        } label: {
            HStack(spacing: 10) {
                AvatarView(
                    initials: contactInitials(contact),
                    color: contactColor(contact),
                    size: 28
                )

                VStack(alignment: .leading, spacing: 1) {
                    if !contact.name.isEmpty {
                        Text(contact.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.textPrimary)
                            .lineLimit(1)
                    }
                    Text(contact.email)
                        .font(.system(size: 11))
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHighlighted ? theme.accentPrimary.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Height of one row: avatar 28 + padding 8*2 = 44, plus divider ~1
    private static let rowHeight: CGFloat = 45

    private var autocompleteDropdown: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, contact in
                        if index > 0 {
                            Divider()
                                .background(theme.divider)
                                .padding(.leading, 44)
                        }

                        contactRow(contact, isHighlighted: index == highlightedIndex)
                            .id(contact.id)
                    }
                }
                .padding(4)
            }
            .scrollContentBackground(.hidden)
            .frame(width: 300, height: Self.rowHeight * min(CGFloat(suggestions.count), 5) + 8)
            .onChange(of: highlightedIndex) { _ in
                if highlightedIndex < suggestions.count {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(suggestions[highlightedIndex].id, anchor: .center)
                    }
                }
            }
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
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
