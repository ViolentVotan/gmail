import SwiftUI

struct CommandPaletteView: View {
    @Bindable var viewModel: CommandPaletteViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
                .padding(.horizontal, Spacing.xl)
            commandList
        }
        .accessibilityLabel("Command palette")
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: ScaleToken.enterFrom)),
                removal: .opacity.combined(with: .scale(scale: 0.9))
            )
        )
        .frame(width: 500)
        .frame(maxHeight: 400)
        .floatingPanelStyle(cornerRadius: CornerRadius.md)
        .onKeyPress(.escape) {
            viewModel.dismiss()
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.moveUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.moveDown()
            return .handled
        }
        .onKeyPress(.return) {
            viewModel.executeSelected()
            return .handled
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Type a command...", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(Typography.title)
                .focused($isSearchFocused)
                .onSubmit { viewModel.executeSelected() }
        }
        .padding(Spacing.md)
        .onAppear { isSearchFocused = true }
    }

    private var commandList: some View {
        Group {
            if viewModel.filteredCommands.isEmpty {
                ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text(viewModel.query.isEmpty ? "Start typing a command" : "No commands match \"\(viewModel.query)\""))
                    .padding()
            } else {
                ScrollView {
                    ScrollViewReader { proxy in
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(viewModel.filteredCommands.enumerated()), id: \.element.id) { index, command in
                                Button {
                                    viewModel.selectedIndex = index
                                    viewModel.executeSelected()
                                } label: {
                                    commandRow(command, isSelected: index == viewModel.selectedIndex)
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                        .onChange(of: viewModel.selectedIndex) { _, newIndex in
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 300)
    }

    private func commandRow(_ command: Command, isSelected: Bool) -> some View {
        HStack {
            Image(systemName: command.icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            Text(command.title)
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(isSelected ? Color.accentColor.opacity(OpacityToken.interactive) : .clear)
        .contentShape(Rectangle())
        .accessibilityLabel(command.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
