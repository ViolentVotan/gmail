import SwiftUI

/// Shared recipient field group (To / Cc / Bcc) used by both ComposeView and ReplyBarView.
struct ComposeRecipientFields: View {
    @Bindable var composeVM: ComposeViewModel
    let contacts: [StoredContact]
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            AutocompleteTextField(label: "To", placeholder: "Recipients", text: $composeVM.to, contacts: contacts)
                .accessibilityLabel("To")
                .accessibilityHint("Enter recipient email addresses")

            Divider().padding(.horizontal, compact ? Spacing.lg : Spacing.xl)

            if composeVM.showCc {
                AutocompleteTextField(label: "Cc", placeholder: "Cc recipients", text: $composeVM.cc, contacts: contacts)
                    .accessibilityLabel("Cc")
                    .accessibilityHint("Enter carbon copy recipient email addresses")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                Divider().padding(.horizontal, compact ? Spacing.lg : Spacing.xl)
            }

            if composeVM.showBcc {
                AutocompleteTextField(label: "Bcc", placeholder: "Bcc recipients", text: $composeVM.bcc, contacts: contacts)
                    .accessibilityLabel("Bcc")
                    .accessibilityHint("Enter blind carbon copy recipient email addresses")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                Divider().padding(.horizontal, compact ? Spacing.lg : Spacing.xl)
            }

            HStack(spacing: 8) {
                Spacer()

                Button {
                    withAnimation(VikAnimation.springSnappy) { composeVM.showCc.toggle() }
                } label: {
                    Text("Cc")
                        .font(Typography.caption)
                        .foregroundStyle(composeVM.showCc ? .primary : .tertiary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .glassEffect(composeVM.showCc ? .regular.interactive() : .identity, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Toggle Cc field")
                .accessibilityHint(composeVM.showCc ? "Hides the Cc field" : "Shows the Cc field")

                Button {
                    withAnimation(VikAnimation.springSnappy) { composeVM.showBcc.toggle() }
                } label: {
                    Text("Bcc")
                        .font(Typography.caption)
                        .foregroundStyle(composeVM.showBcc ? .primary : .tertiary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .glassEffect(composeVM.showBcc ? .regular.interactive() : .identity, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Toggle Bcc field")
                .accessibilityHint(composeVM.showBcc ? "Hides the Bcc field" : "Shows the Bcc field")
            }
            .padding(.horizontal, compact ? Spacing.lg : Spacing.xl)
            .padding(.vertical, Spacing.sm)
        }
    }
}
