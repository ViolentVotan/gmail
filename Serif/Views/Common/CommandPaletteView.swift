import SwiftUI

struct CommandPaletteView: View {
    @Bindable var viewModel: CommandPaletteViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            commandList
        }
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
                .font(.title3)
                .onSubmit { viewModel.executeSelected() }
        }
        .padding(12)
    }

    private var commandList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.filteredCommands.enumerated()), id: \.element.id) { index, command in
                    commandRow(command, isSelected: index == viewModel.selectedIndex)
                        .onTapGesture {
                            viewModel.selectedIndex = index
                            viewModel.executeSelected()
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
    }
}
