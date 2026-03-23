import SwiftUI

struct FormattingToolbar: View {
    var state: WebRichTextEditorState
    @State private var showColorPopover = false
    @State private var showHighlightPopover = false
    @State private var showLinkPopover = false
    @State private var linkURL = ""
    @State private var linkText = ""

    private let fontSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 36]

    private let colorGrid: [[NSColor]] = [
        [.white, NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1), NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1), NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1), .black],
        [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal],
        [.systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown],
    ]

    private let fontFamilies: [(display: String, css: String)] = [
        ("Sans Serif", "system-ui, -apple-system, sans-serif"),
        ("Serif", "Georgia, serif"),
        ("Monospace", "ui-monospace, SFMono-Regular, monospace"),
        ("Arial", "Arial, Helvetica, sans-serif"),
        ("Verdana", "Verdana, Geneva, sans-serif"),
        ("Trebuchet MS", "Trebuchet MS, sans-serif"),
        ("Georgia", "Georgia, Times New Roman, serif"),
        ("Times New Roman", "Times New Roman, Times, serif"),
        ("Courier New", "Courier New, Courier, monospace"),
        ("Comic Sans MS", "Comic Sans MS, cursive"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                UndoRedoGroup(state: state)
                separator
                FontFamilyGroup(state: state, fontFamilies: fontFamilies)
                separator
                FontSizeGroup(state: state, fontSizes: fontSizes)
                separator
                TextStyleGroup(state: state)
                separator
                ColorGroup(
                    state: state,
                    colorGrid: colorGrid,
                    showColorPopover: $showColorPopover,
                    showHighlightPopover: $showHighlightPopover
                )
                separator
                AlignmentGroup(state: state)
                separator
                ListGroup(state: state)
                separator
                IndentAndInsertGroup(
                    state: state,
                    showLinkPopover: $showLinkPopover,
                    linkURL: $linkURL,
                    linkText: $linkText
                )
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
        }
        .onChange(of: state.linkPopoverRequest?.text) { _, _ in
            if let request = state.linkPopoverRequest {
                linkURL = request.url.isEmpty ? "https://" : request.url
                linkText = request.text
                showLinkPopover = true
                state.linkPopoverRequest = nil
            }
        }
    }

    // MARK: - Toolbar Groups

    private struct UndoRedoGroup: View {
        var state: WebRichTextEditorState

        var body: some View {
            Group {
                toolbarButton(icon: "arrow.uturn.backward", tooltip: "Undo") {
                    state.undo()
                }
                toolbarButton(icon: "arrow.uturn.forward", tooltip: "Redo") {
                    state.redo()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("History")
        }
    }

    private struct FontFamilyGroup: View {
        var state: WebRichTextEditorState
        let fontFamilies: [(display: String, css: String)]

        var body: some View {
            Group {
                Menu {
                    ForEach(fontFamilies, id: \.css) { font in
                        Button {
                            state.setFontFamily(font.css)
                        } label: {
                            HStack {
                                Text(font.display)
                                if displayNameForFont(state.fontFamily) == font.display {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(displayNameForFont(state.fontFamily))
                            .font(Typography.captionRegular)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(Typography.captionSmallRegular)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm), interactive: true)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 110)

                ToolbarSeparator()

                toolbarButton(icon: "textformat", tooltip: "Remove formatting") {
                    state.removeFormat()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Font")
        }

        private func displayNameForFont(_ rawFamily: String) -> String {
            let lower = rawFamily.lowercased()
            for ff in fontFamilies {
                if ff.css.lowercased().contains(lower) || ff.display.lowercased() == lower {
                    return ff.display
                }
            }
            return rawFamily.isEmpty ? "Sans Serif" : rawFamily
        }
    }

    private struct FontSizeGroup: View {
        var state: WebRichTextEditorState
        let fontSizes: [CGFloat]

        var body: some View {
            Group {
                Menu {
                    ForEach(fontSizes, id: \.self) { size in
                        Button {
                            state.setFontSize(size)
                        } label: {
                            HStack {
                                Text("\(Int(size))")
                                if state.fontSize == size {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(Int(state.fontSize))")
                            .font(Typography.captionRegular)
                        Image(systemName: "chevron.down")
                            .font(Typography.captionSmallRegular)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm), interactive: true)
                }
                .buttonStyle(.plain)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Font size")
        }
    }

    private struct TextStyleGroup: View {
        var state: WebRichTextEditorState

        var body: some View {
            Group {
                toggleButton(icon: "bold", tooltip: "Bold", isActive: state.isBold) {
                    state.toggleBold()
                }
                toggleButton(icon: "italic", tooltip: "Italic", isActive: state.isItalic) {
                    state.toggleItalic()
                }
                toggleButton(icon: "underline", tooltip: "Underline", isActive: state.isUnderline) {
                    state.toggleUnderline()
                }
                toggleButton(icon: "strikethrough", tooltip: "Strikethrough", isActive: state.isStrikethrough) {
                    state.toggleStrikethrough()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Text style")
        }
    }

    private struct ColorGroup: View {
        var state: WebRichTextEditorState
        let colorGrid: [[NSColor]]
        @Binding var showColorPopover: Bool
        @Binding var showHighlightPopover: Bool

        var body: some View {
            Group {
                Button {
                    showColorPopover.toggle()
                } label: {
                    VStack(spacing: 1) {
                        Text("A")
                            .font(Typography.bodyBold)
                            .foregroundStyle(Color(nsColor: state.textColor))
                        RoundedRectangle(cornerRadius: CornerRadius.indicator)
                            .fill(Color(nsColor: state.textColor))
                            .frame(width: 12, height: 2)
                    }
                    .frame(width: ButtonSize.sm, height: ButtonSize.sm)
                }
                .buttonStyle(.plain)
                .help("Text color")
                .accessibilityLabel("Text color")
                .popover(isPresented: $showColorPopover, arrowEdge: .bottom) {
                    ColorPickerPopover(
                        selectedColor: state.textColor,
                        colorGrid: colorGrid,
                        allowRemove: false,
                        onSelect: { state.setTextColor($0) },
                        isPresented: $showColorPopover
                    )
                }

                Button {
                    showHighlightPopover.toggle()
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "highlighter")
                            .font(Typography.subheadRegular)
                            .foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: CornerRadius.indicator)
                            .fill(state.highlightColor.map { Color(nsColor: $0) } ?? Color.clear)
                            .frame(width: 12, height: 2)
                    }
                    .frame(width: ButtonSize.sm, height: ButtonSize.sm)
                }
                .buttonStyle(.plain)
                .help("Highlight color")
                .accessibilityLabel("Highlight color")
                .popover(isPresented: $showHighlightPopover, arrowEdge: .bottom) {
                    ColorPickerPopover(
                        selectedColor: state.highlightColor,
                        colorGrid: colorGrid,
                        allowRemove: true,
                        onSelect: { state.setHighlightColor($0) },
                        onRemove: { state.removeHighlightColor() },
                        isPresented: $showHighlightPopover
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Color")
        }
    }

    private struct AlignmentGroup: View {
        var state: WebRichTextEditorState

        var body: some View {
            Group {
                alignmentButton(icon: "text.alignleft", alignment: .left, tooltip: "Align left")
                alignmentButton(icon: "text.aligncenter", alignment: .center, tooltip: "Center")
                alignmentButton(icon: "text.alignright", alignment: .right, tooltip: "Align right")
                alignmentButton(icon: "text.justify", alignment: .justified, tooltip: "Justify")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Alignment")
        }

        private func alignmentButton(icon: String, alignment: NSTextAlignment, tooltip: String) -> some View {
            let isActive = state.alignment == alignment
            return Button {
                state.setAlignment(alignment)
            } label: {
                Image(systemName: icon)
                    .font(isActive ? Typography.subheadBold : Typography.subheadRegular)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: ButtonSize.sm, height: ButtonSize.sm)
                    .modifier(ToggleHighlight(isActive: isActive))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .help(tooltip)
            .accessibilityLabel(tooltip)
        }
    }

    private struct ListGroup: View {
        var state: WebRichTextEditorState

        var body: some View {
            Group {
                toolbarButton(icon: "list.number", tooltip: "Numbered list") {
                    state.insertNumberedList()
                }
                toolbarButton(icon: "list.bullet", tooltip: "Bullet list") {
                    state.insertBulletList()
                }
                toggleButton(icon: "text.quote", tooltip: "Blockquote", isActive: state.isBlockquote) {
                    state.toggleBlockquote()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Lists")
        }
    }

    private struct IndentAndInsertGroup: View {
        var state: WebRichTextEditorState
        @Binding var showLinkPopover: Bool
        @Binding var linkURL: String
        @Binding var linkText: String

        var body: some View {
            Group {
                toolbarButton(icon: "decrease.indent", tooltip: "Decrease indent") {
                    state.decreaseIndent()
                }
                toolbarButton(icon: "increase.indent", tooltip: "Increase indent") {
                    state.increaseIndent()
                }

                ToolbarSeparator()

                toolbarButton(icon: "globe", tooltip: "Translate") {
                    state.translationRequested = true
                }

                ToolbarSeparator()

                Button {
                    linkURL = "https://"
                    linkText = state.selectedText
                    showLinkPopover.toggle()
                } label: {
                    Image(systemName: "link")
                        .font(Typography.subheadRegular)
                        .foregroundStyle(.secondary)
                        .frame(width: ButtonSize.sm, height: ButtonSize.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Insert link (Cmd+K)")
                .accessibilityLabel("Insert link")
                .popover(isPresented: $showLinkPopover, arrowEdge: .bottom) {
                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Text("URL")
                                .font(Typography.captionRegular)
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .leading)
                            TextField("https://", text: $linkURL)
                                .textFieldStyle(.roundedBorder)
                                .font(Typography.subheadRegular)
                        }
                        HStack(spacing: 6) {
                            Text("Text")
                                .font(Typography.captionRegular)
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .leading)
                            TextField("Display text (optional)", text: $linkText)
                                .textFieldStyle(.roundedBorder)
                                .font(Typography.subheadRegular)
                        }
                        HStack {
                            Spacer()
                            Button("Cancel") {
                                showLinkPopover = false
                            }
                            .font(Typography.captionRegular)
                            .buttonStyle(.glass)
                            .controlSize(.small)

                            Button("Insert") {
                                let text = linkText.isEmpty ? nil : linkText
                                state.insertLink(url: linkURL, text: text)
                                showLinkPopover = false
                            }
                            .font(Typography.caption)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(linkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                      linkURL == "https://")
                        }
                    }
                    .padding(Spacing.md)
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 340)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Indentation and insert")
        }
    }

    // MARK: - Helpers

    private var separator: some View {
        ToolbarSeparator()
    }
}

// MARK: - Shared Toolbar Helpers

private struct ToolbarSeparator: View {
    var body: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 6)
    }
}

private func toolbarButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .font(Typography.subheadRegular)
            .foregroundStyle(.secondary)
            .frame(width: ButtonSize.sm, height: ButtonSize.sm)
            .contentShape(Rectangle())
    }
    .buttonStyle(.glass)
    .accessibilityLabel(tooltip)
    .help(tooltip)
}

private func toggleButton(icon: String, tooltip: String, isActive: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .font(isActive ? Typography.subheadBold : Typography.subheadRegular)
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .frame(width: ButtonSize.sm, height: ButtonSize.sm)
            .modifier(ToggleHighlight(isActive: isActive))
            .contentShape(Rectangle())
    }
    .buttonStyle(.glass)
    .accessibilityLabel(tooltip)
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
    .help(tooltip)
}

// MARK: - Toggle Highlight

private struct ToggleHighlight: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.glassOrMaterial(in: .rect(cornerRadius: CornerRadius.sm), interactive: true)
        } else {
            content
        }
    }
}

// MARK: - Color Picker Popover

struct ColorPickerPopover: View {
    let selectedColor: NSColor?
    let colorGrid: [[NSColor]]
    let allowRemove: Bool
    let onSelect: (NSColor) -> Void
    var onRemove: (() -> Void)? = nil
    @Binding var isPresented: Bool
    @State private var customColor: Color = .white

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                ForEach(0..<colorGrid.count, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<colorGrid[row].count, id: \.self) { col in
                            let color = colorGrid[row][col]
                            Button {
                                onSelect(color)
                                isPresented = false
                            } label: {
                                RoundedRectangle(cornerRadius: CornerRadius.xs)
                                    .fill(Color(nsColor: color))
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: CornerRadius.xs)
                                            .stroke(
                                                isSelected(color) ? Color.primary : Color.primary.opacity(OpacityToken.interactive),
                                                lineWidth: isSelected(color) ? 2 : 1
                                            )
                                    )
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Text color: \(colorName(for: color))")
                            .accessibilityAddTraits(isSelected(color) ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                ColorPicker("", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 24, height: 24)

                Text("Custom")
                    .font(Typography.captionRegular)
                    .foregroundStyle(.secondary)

                Spacer()

                if allowRemove {
                    Button("Remove") {
                        onRemove?()
                        isPresented = false
                    }
                    .font(Typography.captionRegular)
                    .buttonStyle(.plain)
                }

                Button("Apply") {
                    onSelect(NSColor(customColor))
                    isPresented = false
                }
                .font(Typography.caption)
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(minWidth: 160, idealWidth: 170, maxWidth: 220)
    }

    private func isSelected(_ color: NSColor) -> Bool {
        guard let selected = selectedColor else { return false }
        let c1 = color.usingColorSpace(.deviceRGB) ?? color
        let c2 = selected.usingColorSpace(.deviceRGB) ?? selected
        return abs(c1.redComponent - c2.redComponent) < 0.05
            && abs(c1.greenComponent - c2.greenComponent) < 0.05
            && abs(c1.blueComponent - c2.blueComponent) < 0.05
    }

    private func colorName(for color: NSColor) -> String {
        let nameMap: [(NSColor, String)] = [
            (.white, "White"), (.black, "Black"),
            (.systemRed, "Red"), (.systemOrange, "Orange"),
            (.systemYellow, "Yellow"), (.systemGreen, "Green"),
            (.systemTeal, "Teal"), (.systemBlue, "Blue"),
            (.systemIndigo, "Indigo"), (.systemPurple, "Purple"),
            (.systemPink, "Pink"), (.systemBrown, "Brown"),
        ]
        for (knownColor, name) in nameMap {
            let c1 = color.usingColorSpace(.deviceRGB) ?? color
            let c2 = knownColor.usingColorSpace(.deviceRGB) ?? knownColor
            if abs(c1.redComponent - c2.redComponent) < 0.05
                && abs(c1.greenComponent - c2.greenComponent) < 0.05
                && abs(c1.blueComponent - c2.blueComponent) < 0.05 {
                return name
            }
        }
        return "Gray"
    }
}
