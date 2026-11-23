import SwiftUI

// look and feel: the purple from the website, close to obsidian's

enum Theme {
    static let accent = Color(light: 0x4b44c8, dark: 0x8a84ff)
    static let accentSoft = Color(light: 0x4b44c8, dark: 0x8a84ff).opacity(0.16)
    static let sidebarSelection = Color.primary.opacity(0.08)
}

private struct RowSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// true inside a list row that is drawn selected, so text can switch to white on the purple box
    var rowSelected: Bool {
        get { self[RowSelectedKey.self] }
        set { self[RowSelectedKey.self] = newValue }
    }
}

extension View {
    /// a list row that selects on click and shows the purple rounded box when selected,
    /// instead of the system highlight
    func selectableRow(_ id: String, selection: Binding<String?>) -> some View {
        let on = selection.wrappedValue == id
        return self
            .environment(\.rowSelected, on)
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.accent : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture { selection.wrappedValue = id }
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// up and down arrows move the selection through the given ids
    func arrowSelection(_ ids: [String], selection: Binding<String?>) -> some View {
        self
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) {
                guard !ids.isEmpty else { return .ignored }
                let i = selection.wrappedValue.flatMap { ids.firstIndex(of: $0) } ?? -1
                selection.wrappedValue = ids[min(ids.count - 1, i + 1)]
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !ids.isEmpty else { return .ignored }
                let i = selection.wrappedValue.flatMap { ids.firstIndex(of: $0) } ?? ids.count
                selection.wrappedValue = ids[max(0, i - 1)]
                return .handled
            }
    }
}

/// a small count in a soft purple capsule, white when its row is selected
struct CountBadge: View {
    @Environment(\.rowSelected) private var selected
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(selected ? Color.white : Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Theme.accentSoft))
    }
}
