import SwiftUI

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String? = nil
    let symbol: String
    /// Hidden until you type, so an accidental ⌘K → ↩ can't quit anything.
    var needsQuery = false
    let run: () -> Void
}

enum PaletteSearch {
    /// Every typed word must appear in the title or subtitle (order-free, case-insensitive).
    static func matches(_ c: PaletteCommand, _ query: String) -> Bool {
        let hay = (c.title + " " + (c.subtitle ?? "")).lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { hay.contains($0) }
    }

    static func filter(_ commands: [PaletteCommand], _ query: String) -> [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return commands.filter { !$0.needsQuery } }
        let hits = commands.filter { matches($0, q) }
        // Titles that start with the query rank first.
        return hits.filter { $0.title.lowercased().hasPrefix(q.lowercased()) } + hits.filter { !$0.title.lowercased().hasPrefix(q.lowercased()) }
    }
}

struct CommandPalette: View {
    let commands: [PaletteCommand]
    let dismiss: () -> Void
    @Local private var query = ""
    @Local private var index = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = Array(PaletteSearch.filter(commands, query).prefix(9))
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "command").foregroundStyle(.secondary)
                    TextField("Type a command: quit, clean, awake, duplicates…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { run(results) }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, c in
                        HStack(spacing: 12) {
                            Image(systemName: c.symbol).font(.system(size: 13)).frame(width: 20).foregroundStyle(.secondary)
                            Text(c.title).font(.system(size: 13))
                            if let s = c.subtitle { Text(s).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1) }
                            Spacer()
                            if i == index { Text("↩").font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(i == index ? Color.primary.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                        .onTapGesture { index = i; run(results) }
                    }
                    if results.isEmpty {
                        Text("No matching command").font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                    }
                }
                .padding(6)
            }
            .frame(width: 580)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.top, 80)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func run(_ results: [PaletteCommand]) {
        guard results.indices.contains(index) else { return }
        dismiss()
        results[index].run()
    }
}
