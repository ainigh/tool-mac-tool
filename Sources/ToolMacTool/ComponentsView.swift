import AppKit
import SwiftUI
import ToolCore

// The Components window: every component a note can hold, by group, each with what it's for, a
// live one to try (filled in with an example: nothing's saved), the text it's kept as in the note,
// and how to put one in: type "/" in a note, or add it to the end of a note from here.

@MainActor
enum ComponentsWindow {
    static func show(boards: BoardStore) {
        Windows.show("components", title: "Note components", size: NSSize(width: 900, height: 620)) {
            ComponentsView(boards: boards)
        }
    }
}

struct ComponentsView: View {
    @ObservedObject var boards: BoardStore
    @State private var picked: NoteComponentType = .checklist
    @State private var search = ""
    /// The one to try, as it's been changed (reset when another's picked).
    @State private var trial = NoteComponentType.checklist.sample()
    @State private var added: String?

    private var shown: [NoteComponentType] {
        search.isEmpty ? NoteComponentType.allCases : NoteComponentType.matching(search)
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 270)
            Divider()
            ScrollView { detail(picked).padding(24) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: picked) { _, now in
            trial = now.sample()
            added = nil
        }
    }

    // MARK: The list

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Components")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Blocks a note can hold. Type / in any note to put one in.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(NoteComponentType.Group.allCases, id: \.self) { group in
                        let items = shown.filter { $0.group == group }
                        if !items.isEmpty {
                            Text(group.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(ComponentLook.color(group))
                                .padding(.top, 10)
                                .padding(.leading, 6)
                            ForEach(items, id: \.self) { type in row(type) }
                        }
                    }
                    if shown.isEmpty {
                        Text("None match \u{201C}\(search)\u{201D}").foregroundStyle(.secondary).padding(8)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 34)
        .padding(.bottom, 12)
        .background(Color.primary.opacity(0.03))
    }

    private func row(_ type: NoteComponentType) -> some View {
        let lit = type == picked
        let color = ComponentLook.color(type.group)
        return Button { picked = type } label: {
            HStack(spacing: 9) {
                Image(systemName: type.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(lit ? .white : color)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(lit ? color : color.opacity(0.14)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(type.title).font(.system(size: 12.5, weight: .semibold))
                    Text(type.summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lit ? color.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: One component

    private func detail(_ type: NoteComponentType) -> some View {
        let color = ComponentLook.color(type.group)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: type.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.gradient))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(type.title).font(.system(size: 24, weight: .bold, design: .rounded))
                        Text(type.group.rawValue)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Capsule().fill(color.opacity(0.13)))
                    }
                    Text(type.summary)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("Try it", note: "A live one, with an example in it: use it as you would in a note (nothing here is saved).") {
                ComponentView(component: $trial, style: ComponentStyle(ink: Color(white: 0.12), size: 13)) { change in
                    if case .replace(let text) = change, let c = NoteDocument(text).components.first { trial = c }
                    if case .remove = change { trial = type.sample() }
                }
                .padding(12)
                .frame(maxWidth: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 1, green: 0.98, blue: 0.9)))
                .environment(\.colorScheme, .light)
            }

            section("How to add one", note: nil) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("In any note, type")
                        Text("/" + (type.title.split(separator: " ").first.map { $0.lowercased() } ?? type.rawValue))
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                        Text("and press Return.")
                    }
                    .font(.system(size: 13))
                    HStack(spacing: 8) {
                        Menu {
                            let notes = boards.notes.filter { $0.title != nil }
                            if notes.isEmpty { Text("No notes with a title yet") }
                            ForEach(BoardStore.kinds, id: \.id) { kind in
                                let mine = notes.filter { $0.board == kind }
                                if !mine.isEmpty {
                                    Section(kind.name) {
                                        ForEach(mine) { note in
                                            Button(note.title ?? note.place) { add(type, to: note) }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Add to the end of a note…", systemImage: "note.text.badge.plus")
                        }
                        .fixedSize()
                        Button {
                            Clipboard.copy(type.template())
                            added = "Copied: paste it into a note"
                        } label: {
                            Label("Copy a blank one", systemImage: "doc.on.doc")
                        }
                        if let added {
                            Text(added).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            section("As text", note: "What it's kept as in the note: plain text you can read, search, copy or write by hand.") {
                Text(trial.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            if let note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            content()
        }
    }

    private func add(_ type: NoteComponentType, to note: BoardStore.Note) {
        boards.append(type.template(), note.board, note.index)
        added = "Added to \u{201C}\(note.title ?? note.place)\u{201D}"
    }
}
