import SwiftUI
import WebKit

struct InAppBrowserView: View {
    let url: URL
    let onClose: () -> Void
    @State private var page = WebPage()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                // Close button
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(Typography.subhead)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm), interactive: true)
                }
                .buttonStyle(.plain)
                .help("Close")
                .keyboardShortcut(.escape, modifiers: [])

                // Navigation
                Button {
                    if let item = page.backForwardList.backList.last {
                        page.load(item)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(Typography.subhead)
                        .foregroundStyle(!page.backForwardList.backList.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(page.backForwardList.backList.isEmpty)
                .help("Back")

                Button {
                    if let item = page.backForwardList.forwardList.first {
                        page.load(item)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(Typography.subhead)
                        .foregroundStyle(!page.backForwardList.forwardList.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(page.backForwardList.forwardList.isEmpty)
                .help("Forward")

                // URL bar
                HStack(spacing: 6) {
                    if page.isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(Typography.captionSmallRegular)
                            .foregroundStyle(.tertiary)
                    }
                    Text(displayURL)
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                        .strokeBorder(.separator, lineWidth: 1)
                )

                // Open in browser
                Button {
                    NSWorkspace.shared.open(page.url ?? url)
                    onClose()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "safari")
                            .font(Typography.subheadRegular)
                        Text("Open in Browser")
                            .font(Typography.subhead)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm), interactive: true)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.sm)
                            .strokeBorder(.separator, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Open in default browser")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Loading progress
            if page.isLoading {
                ProgressView(value: page.estimatedProgress)
                    .tint(.accentColor)
            }

            // WebView
            WebView(page)
        }
        .task {
            page.load(URLRequest(url: url))
        }
    }

    private var displayURL: String {
        let displayedURL = page.url ?? url
        if let host = displayedURL.host {
            return host + displayedURL.path
        }
        return displayedURL.absoluteString
    }
}
