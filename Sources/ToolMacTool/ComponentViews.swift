import AppKit
import SwiftUI
import ToolCore
import UniformTypeIdentifiers

// Each kind of note component, drawn to use. Every change is written straight back into the
// component's text (`NoteComponent`), which is written back into the note: nothing is kept
// anywhere else. Hover a component for its menu: move it, copy it, edit it as text, delete it.

/// How components look in the note they're in: its ink, and its text size.
struct ComponentStyle {
    var ink: Color
    var size: CGFloat

    var faint: Color { ink.opacity(0.45) }
    var wash: Color { ink.opacity(0.06) }
    func font(_ scale: CGFloat = 1, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        .system(size: max(9, size * scale), weight: weight, design: mono ? .monospaced : .default)
    }
}

enum ComponentLook {
    static func color(_ group: NoteComponentType.Group) -> Color {
        switch group {
        case .lists: return Color(red: 0.2, green: 0.5, blue: 0.95)
        case .records: return Color(red: 0.55, green: 0.38, blue: 0.95)
        case .tracking: return Color(red: 0.12, green: 0.66, blue: 0.45)
        case .text: return Color(red: 0.93, green: 0.55, blue: 0.12)
        case .media: return Color(red: 0.9, green: 0.3, blue: 0.5)
        case .run: return Color(red: 0.95, green: 0.4, blue: 0.2)
        }
    }

    static func color(_ type: NoteComponentType?) -> Color { type.map { color($0.group) } ?? .gray }
}

// MARK: - The frame round each one

struct ComponentView: View {
    enum Change {
        case remove, moveUp, moveDown, duplicate
        /// Edited as text: what it reads as now.
        case replace(String)
    }

    @Binding var component: NoteComponent
    let style: ComponentStyle
    var canMoveUp = true
    var canMoveDown = true
    let change: (Change) -> Void
    @State private var hover = false
    @State private var raw: String?

    var body: some View {
        let type = component.type
        let accent = ComponentLook.color(type)
        // A divider and columns sit in the note as its text does, with no card round them.
        let bare = type == .divider || type == .columns
        VStack(alignment: .leading, spacing: 0) {
            if let raw {
                rawEditor(raw)
            } else {
                ComponentContent(c: $component, s: style, accent: accent)
            }
        }
        .padding(bare ? 2 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !bare {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.wash)
            }
        }
        .overlay {
            if !bare {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hover ? accent.opacity(0.55) : style.ink.opacity(0.08), lineWidth: hover ? 1 : 0.5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hover, raw == nil { menu.padding(3) }
        }
        .onHover { hover = $0 }
        .contextMenu { menuItems }
        .animation(.easeInOut(duration: 0.12), value: hover)
    }

    private var menu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(style.ink.opacity(0.6))
                .frame(width: 20, height: 16)
                .background(Capsule().fill(style.ink.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(component.type?.title ?? "Component"): move, copy, edit as text, delete")
    }

    @ViewBuilder private var menuItems: some View {
        Button("Move up") { change(.moveUp) }.disabled(!canMoveUp)
        Button("Move down") { change(.moveDown) }.disabled(!canMoveDown)
        Button("Duplicate") { change(.duplicate) }
        Divider()
        Button("Copy as text") { Clipboard.copy(component.text) }
        Button("Edit as text…") { raw = component.text }
        Divider()
        Button("Delete \(component.type?.title.lowercased() ?? "component")", role: .destructive) { change(.remove) }
    }

    private func rawEditor(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("As text: it's kept in the note like this")
                .font(style.font(0.75, .medium))
                .foregroundStyle(style.faint)
            TextField("", text: Binding(get: { raw ?? "" }, set: { raw = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(style.font(0.9, mono: true))
                .foregroundStyle(style.ink)
                .lineLimit(3...30)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(style.ink.opacity(0.05)))
            HStack {
                Spacer()
                Button("Cancel") { raw = nil }
                Button("Done") {
                    let new = raw ?? text
                    raw = nil
                    change(.replace(new))
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
    }
}

/// The component itself, by its kind.
private struct ComponentContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color

    var body: some View {
        switch c.type {
        case .checklist: ChecklistContent(c: $c, s: s, accent: accent)
        case .table: TableContent(c: $c, s: s, accent: accent)
        case .kanban: KanbanContent(c: $c, s: s, accent: accent)
        case .proscons: ProsConsContent(c: $c, s: s)
        case .contact: ContactContent(c: $c, s: s, accent: accent)
        case .properties: PropertiesContent(c: $c, s: s)
        case .progress: ProgressContent(c: $c, s: s, accent: accent)
        case .counter: CounterContent(c: $c, s: s, accent: accent)
        case .rating: RatingContent(c: $c, s: s)
        case .countdown: CountdownContent(c: $c, s: s, accent: accent)
        case .habit: HabitContent(c: $c, s: s, accent: accent)
        case .calc: CalcContent(c: $c, s: s, accent: accent)
        case .callout: CalloutContent(c: $c, s: s)
        case .quote: QuoteContent(c: $c, s: s, accent: accent)
        case .code: CodeContent(c: $c, s: s)
        case .toggle: ToggleContent(c: $c, s: s)
        case .divider: DividerContent(c: $c, s: s)
        case .columns: ColumnsContent(c: $c, s: s)
        case .bookmark: BookmarkContent(c: $c, s: s)
        case .image: ImageContent(c: $c, s: s)
        case .snippet: SnippetContent(c: $c, s: s, accent: accent)
        case .action: ActionContent(c: $c, s: s, accent: accent)
        case .shortcut: ShortcutContent(c: $c, s: s, accent: accent)
        case nil: UnknownContent(c: $c, s: s)
        }
    }
}

// MARK: - Bits they share

/// A one-line (or growing) field, plain, in the note's ink.
private struct Field: View {
    let prompt: String
    @Binding var text: String
    let s: ComponentStyle
    var scale: CGFloat = 1
    var weight: Font.Weight = .regular
    var mono = false
    var multiline = false

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt).foregroundColor(s.ink.opacity(0.3)), axis: multiline ? .vertical : .horizontal)
            .textFieldStyle(.plain)
            .font(s.font(scale, weight, mono: mono))
            .foregroundStyle(s.ink)
    }
}

/// The component's title: what's on its first line after its kind.
private struct TitleField: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let prompt: String

    var body: some View {
        Field(prompt: prompt, text: $c.args, s: s, scale: 1.0, weight: .semibold)
    }
}

/// A small button with an icon (and words, when there's room).
private struct MiniButton: View {
    let title: String
    let symbol: String
    let s: ComponentStyle
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(s.font(0.78, .medium))
                .foregroundStyle(tint ?? s.ink.opacity(0.6))
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(Capsule().fill((tint ?? s.ink).opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

private struct RemoveButton: View {
    let s: ComponentStyle
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(s.ink.opacity(0.4))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Take it out")
    }
}

private struct Bar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.16))
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.25), value: fraction)
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Lists & tables

private struct ChecklistContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color
    @FocusState private var focused: Int?

    private var items: [NoteComponents.Item] { NoteComponents.checklist(c.body) }
    private func set(_ items: [NoteComponents.Item]) { c.body = NoteComponents.checklistBody(items) }

    var body: some View {
        let items = self.items
        let counted = items.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let done = counted.filter(\.done).count
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TitleField(c: $c, s: s, prompt: "Checklist")
                Text("\(done)/\(counted.count)")
                    .font(s.font(0.8, .semibold).monospacedDigit())
                    .foregroundStyle(done == counted.count && done > 0 ? accent : s.faint)
            }
            Bar(fraction: counted.isEmpty ? 0 : Double(done) / Double(counted.count), color: accent, height: 4)
                .padding(.bottom, 2)
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Button {
                        var all = self.items
                        guard all.indices.contains(i) else { return }
                        all[i].done.toggle()
                        withAnimation(.easeInOut(duration: 0.15)) { set(all) }
                    } label: {
                        Image(systemName: items[i].done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: s.size * 1.05))
                            .foregroundStyle(items[i].done ? accent : s.ink.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    Field(prompt: "Item", text: Binding(get: { self.items[safe: i]?.text ?? "" }, set: { new in
                        var all = self.items
                        guard all.indices.contains(i) else { return }
                        all[i].text = new
                        set(all)
                    }), s: s)
                    .strikethrough(items[i].done, color: s.faint)
                    .opacity(items[i].done ? 0.55 : 1)
                    .focused($focused, equals: i)
                    .onSubmit {
                        var all = self.items
                        all.insert(.init(text: ""), at: min(i + 1, all.count))
                        set(all)
                        focused = i + 1
                    }
                    RemoveButton(s: s) {
                        var all = self.items
                        guard all.indices.contains(i) else { return }
                        all.remove(at: i)
                        set(all)
                    }
                }
            }
            HStack(spacing: 6) {
                MiniButton(title: "Add an item", symbol: "plus", s: s) {
                    var all = self.items
                    all.append(.init(text: ""))
                    set(all)
                    focused = all.count - 1
                }
                if done > 0 {
                    MiniButton(title: "Clear done", symbol: "checkmark.circle", s: s) {
                        withAnimation { set(self.items.filter { !$0.done }) }
                    }
                }
            }
        }
    }
}

private struct TableContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color

    private var rows: [[String]] {
        let r = NoteComponents.table(c.body)
        return r.isEmpty ? [[""]] : r
    }

    private func set(_ rows: [[String]]) { c.body = NoteComponents.tableBody(rows) }

    var body: some View {
        let rows = self.rows
        let width = rows.first?.count ?? 1
        let totals = NoteComponents.totals(rows)
        VStack(alignment: .leading, spacing: 6) {
            if !c.args.isEmpty { TitleField(c: $c, s: s, prompt: "Table") }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(0..<width, id: \.self) { col in cell(r, col, header: r == 0) }
                        }
                    }
                    if rows.count > 2, totals.contains(where: { $0 != nil }) {
                        GridRow {
                            ForEach(0..<width, id: \.self) { col in
                                Text(totals[safe: col].flatMap { $0 }.map(NoteComponents.format) ?? (col == 0 ? "Total" : ""))
                                    .font(s.font(0.9, .bold).monospacedDigit())
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .frame(minWidth: 64, alignment: .leading)
                            }
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(s.ink.opacity(0.14), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 6) {
                MiniButton(title: "Row", symbol: "plus", s: s) { set(rows + [Array(repeating: "", count: width)]) }
                MiniButton(title: "Column", symbol: "plus", s: s) { set(rows.map { $0 + [""] }) }
                if c.args.isEmpty {
                    MiniButton(title: "Title", symbol: "textformat", s: s) { c.args = "Table" }
                }
            }
        }
    }

    private func cell(_ r: Int, _ col: Int, header: Bool) -> some View {
        Field(prompt: header ? "Heading" : "", text: Binding(get: { self.rows[safe: r]?[safe: col] ?? "" }, set: { new in
            var all = self.rows
            guard all.indices.contains(r), all[r].indices.contains(col) else { return }
            all[r][col] = new
            set(all)
        }), s: s, scale: 0.92, weight: header ? .semibold : .regular)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minWidth: 64, alignment: .leading)
        .background(header ? s.ink.opacity(0.07) : Color.clear)
        .overlay(Rectangle().strokeBorder(s.ink.opacity(0.08), lineWidth: 0.5))
        .contextMenu {
            Button("Insert a row below") {
                var all = self.rows
                all.insert(Array(repeating: "", count: all.first?.count ?? 1), at: min(r + 1, all.count))
                set(all)
            }
            Button("Insert a column to the right") { set(self.rows.map { var row = $0; row.insert("", at: min(col + 1, row.count)); return row }) }
            Divider()
            Button("Delete this row") {
                var all = self.rows
                guard all.count > 1, all.indices.contains(r) else { return }
                all.remove(at: r)
                set(all)
            }
            .disabled(rows.count <= 1)
            Button("Delete this column") {
                guard (self.rows.first?.count ?? 0) > 1 else { return }
                set(self.rows.map { var row = $0; if row.indices.contains(col) { row.remove(at: col) }; return row })
            }
            .disabled((rows.first?.count ?? 0) <= 1)
        }
    }
}

private struct KanbanContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color

    private var columns: [NoteComponents.Column] {
        let cols = NoteComponents.kanban(c.body)
        return cols.isEmpty ? [.init("To do")] : cols
    }

    private func set(_ cols: [NoteComponents.Column]) { c.body = NoteComponents.kanbanBody(cols) }

    var body: some View {
        let cols = columns
        VStack(alignment: .leading, spacing: 6) {
            if !c.args.isEmpty { TitleField(c: $c, s: s, prompt: "Board") }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(cols.indices, id: \.self) { col in column(col, cols) }
                    Button {
                        set(self.columns + [.init("New column")])
                    } label: {
                        Image(systemName: "plus").foregroundStyle(s.faint).frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(s.ink.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help("Add a column")
                }
            }
        }
    }

    private func column(_ col: Int, _ cols: [NoteComponents.Column]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Field(prompt: "Column", text: Binding(get: { self.columns[safe: col]?.title ?? "" }, set: { new in
                    var all = self.columns
                    guard all.indices.contains(col) else { return }
                    all[col].title = new
                    set(all)
                }), s: s, scale: 0.85, weight: .semibold)
                Text("\(cols[col].cards.count)")
                    .font(s.font(0.75, .semibold).monospacedDigit())
                    .foregroundStyle(s.faint)
            }
            ForEach(cols[col].cards.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    Field(prompt: "Card", text: Binding(get: { self.columns[safe: col]?.cards[safe: i] ?? "" }, set: { new in
                        var all = self.columns
                        guard all.indices.contains(col), all[col].cards.indices.contains(i) else { return }
                        all[col].cards[i] = new
                        set(all)
                    }), s: s, scale: 0.88, multiline: true)
                    HStack(spacing: 2) {
                        if col > 0 { arrow("chevron.left", from: col, card: i, to: col - 1) }
                        Spacer(minLength: 0)
                        RemoveButton(s: s) {
                            var all = self.columns
                            guard all.indices.contains(col), all[col].cards.indices.contains(i) else { return }
                            all[col].cards.remove(at: i)
                            set(all)
                        }
                        if col < cols.count - 1 { arrow("chevron.right", from: col, card: i, to: col + 1) }
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(s.ink.opacity(0.08), lineWidth: 0.5))
            }
            MiniButton(title: "Card", symbol: "plus", s: s) {
                var all = self.columns
                guard all.indices.contains(col) else { return }
                all[col].cards.append("")
                set(all)
            }
        }
        .padding(6)
        .frame(width: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(col == cols.count - 1 ? 0.12 : 0.06)))
        .contextMenu {
            Button("Delete the column \u{201C}\(cols[col].title)\u{201D}") {
                var all = self.columns
                guard all.count > 1, all.indices.contains(col) else { return }
                all.remove(at: col)
                set(all)
            }
            .disabled(cols.count <= 1)
        }
    }

    private func arrow(_ symbol: String, from col: Int, card: Int, to target: Int) -> some View {
        Button {
            var all = self.columns
            guard all.indices.contains(col), all.indices.contains(target), all[col].cards.indices.contains(card) else { return }
            let moved = all[col].cards.remove(at: card)
            all[target].cards.append(moved)
            withAnimation(.easeInOut(duration: 0.15)) { set(all) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 16)
                .background(Capsule().fill(accent.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Move it to \u{201C}\(columns[safe: target]?.title ?? "")\u{201D}")
    }
}

private struct ProsConsContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle

    private var lists: (pros: [String], cons: [String]) { NoteComponents.prosCons(c.body) }

    var body: some View {
        let l = lists
        VStack(alignment: .leading, spacing: 6) {
            TitleField(c: $c, s: s, prompt: "What's being decided?")
            HStack(alignment: .top, spacing: 10) {
                side(pros: true, items: l.pros, color: Color(red: 0.12, green: 0.6, blue: 0.3))
                side(pros: false, items: l.cons, color: Color(red: 0.86, green: 0.25, blue: 0.25))
            }
            let diff = l.pros.filter { !$0.isEmpty }.count - l.cons.filter { !$0.isEmpty }.count
            Text(diff == 0 ? "Even" : diff > 0 ? "\(diff) more for" : "\(-diff) more against")
                .font(s.font(0.78, .semibold))
                .foregroundStyle(s.faint)
        }
    }

    private func side(pros: Bool, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(pros ? "For" : "Against", systemImage: pros ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                .font(s.font(0.8, .bold))
                .foregroundStyle(color)
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Text(pros ? "+" : "−").font(s.font(0.9, .bold)).foregroundStyle(color)
                    Field(prompt: pros ? "A reason for" : "A reason against", text: Binding(get: {
                        (pros ? self.lists.pros : self.lists.cons)[safe: i] ?? ""
                    }, set: { new in
                        var l = self.lists
                        if pros, l.pros.indices.contains(i) { l.pros[i] = new }
                        if !pros, l.cons.indices.contains(i) { l.cons[i] = new }
                        c.body = NoteComponents.prosConsBody(pros: l.pros, cons: l.cons)
                    }), s: s, scale: 0.92, multiline: true)
                    RemoveButton(s: s) {
                        var l = self.lists
                        if pros, l.pros.indices.contains(i) { l.pros.remove(at: i) }
                        if !pros, l.cons.indices.contains(i) { l.cons.remove(at: i) }
                        c.body = NoteComponents.prosConsBody(pros: l.pros, cons: l.cons)
                    }
                }
            }
            MiniButton(title: "Add", symbol: "plus", s: s, tint: color) {
                var l = self.lists
                if pros { l.pros.append("") } else { l.cons.append("") }
                c.body = NoteComponents.prosConsBody(pros: l.pros, cons: l.cons)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.08)))
    }
}

// MARK: - Records

/// Fields kept as "Key: value" lines, edited one by one.
private struct FieldRows {
    @Binding var c: NoteComponent

    var fields: [NoteComponents.Field] { NoteComponents.fields(c.body) }

    func set(_ fields: [NoteComponents.Field]) { c.body = NoteComponents.fieldsBody(fields) }

    func value(_ i: Int) -> Binding<String> {
        Binding(get: { fields[safe: i]?.value ?? "" }, set: { new in
            var all = fields
            guard all.indices.contains(i) else { return }
            all[i].value = new
            set(all)
        })
    }

    func key(_ i: Int) -> Binding<String> {
        Binding(get: { fields[safe: i]?.key ?? "" }, set: { new in
            var all = fields
            guard all.indices.contains(i) else { return }
            all[i].key = new.replacingOccurrences(of: ":", with: "")
            set(all)
        })
    }

    func remove(_ i: Int) {
        var all = fields
        guard all.indices.contains(i) else { return }
        all.remove(at: i)
        set(all)
    }
}

private struct ContactContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color
    @State private var copied = false

    var body: some View {
        let rows = FieldRows(c: $c)
        let fields = rows.fields
        let nameIndex = fields.firstIndex { $0.key.lowercased() == "name" }
        let name = nameIndex.map { fields[$0].value } ?? ""
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(Self.initials(name))
                    .font(.system(size: s.size * 1.1, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: s.size * 2.6, height: s.size * 2.6)
                    .background(Circle().fill(accent.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    if let nameIndex {
                        Field(prompt: "Name", text: rows.value(nameIndex), s: s, scale: 1.15, weight: .semibold)
                    } else {
                        Button("Add a name") { rows.set([.init("Name", "")] + fields) }.buttonStyle(.link)
                    }
                    let subtitle = [value("Role", fields), value("Company", fields)].compactMap { $0 }.filter { !$0.isEmpty }
                    if !subtitle.isEmpty {
                        Text(subtitle.joined(separator: " · ")).font(s.font(0.8)).foregroundStyle(s.faint).lineLimit(1)
                    }
                }
            }
            ForEach(fields.indices, id: \.self) { i in
                if i != nameIndex { row(i, fields[i], rows) }
            }
            HStack(spacing: 6) {
                let missing = ContactField.allCases.filter { f in !fields.contains { $0.key.lowercased() == f.rawValue.lowercased() } }
                Menu {
                    ForEach(missing, id: \.self) { f in
                        Button(f.rawValue) { rows.set(fields + [.init(f.rawValue, "")]) }
                    }
                    Divider()
                    Button("Something else…") { rows.set(fields + [.init("Label", "")]) }
                } label: {
                    Label("Add a field", systemImage: "plus").font(s.font(0.78, .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                MiniButton(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc", s: s) {
                    Clipboard.copy(fields.filter { !$0.value.isEmpty }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                }
                MiniButton(title: "Add to Contacts", symbol: "person.crop.circle.badge.plus", s: s) { Self.openVCard(fields) }
                    .help("Opens it in Contacts, to add")
            }
        }
    }

    private func value(_ key: String, _ fields: [NoteComponents.Field]) -> String? {
        fields.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    private func row(_ i: Int, _ f: NoteComponents.Field, _ rows: FieldRows) -> some View {
        let known = ContactField.allCases.first { $0.rawValue.lowercased() == f.key.lowercased() }
        return HStack(spacing: 6) {
            Image(systemName: known?.symbol ?? "tag")
                .font(.system(size: s.size * 0.8))
                .foregroundStyle(accent)
                .frame(width: 16)
            if known == nil {
                Field(prompt: "Label", text: rows.key(i), s: s, scale: 0.8, weight: .medium)
                    .frame(width: 70)
            }
            Field(prompt: known?.rawValue ?? "Value", text: rows.value(i), s: s, scale: 0.92, multiline: known == .address || known == .notes)
            if let link = Self.link(known, f.value) {
                Button { NSWorkspace.shared.open(link) } label: {
                    Image(systemName: known == .phone ? "phone.arrow.up.right" : known == .email ? "paperplane" : known == .address ? "map" : "arrow.up.right.square")
                        .font(.system(size: s.size * 0.8, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help(known == .phone ? "Call" : known == .email ? "Write an email" : known == .address ? "Open in Maps" : "Open")
            }
            RemoveButton(s: s) { rows.remove(i) }
        }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }

    static func link(_ field: ContactField?, _ value: String) -> URL? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, let field else { return nil }
        switch field {
        case .phone:
            let digits = v.filter { $0.isNumber || $0 == "+" }
            return digits.isEmpty ? nil : URL(string: "tel:" + digits)
        case .email: return v.contains("@") ? URL(string: "mailto:" + v) : nil
        case .address:
            return v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap { URL(string: "http://maps.apple.com/?q=" + $0) }
        case .website: return URL(string: v.contains("://") ? v : "https://" + v)
        default: return nil
        }
    }

    /// The contact as a card Contacts opens (to add it there).
    static func openVCard(_ fields: [NoteComponents.Field]) {
        func get(_ k: String) -> String { fields.first { $0.key.lowercased() == k.lowercased() }?.value ?? "" }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: "\n", with: "\\n")
        }
        let name = get("Name")
        let parts = name.split(separator: " ")
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "FN:" + esc(name),
                     "N:" + esc(parts.dropFirst().joined(separator: " ")) + ";" + esc(parts.first.map(String.init) ?? "") + ";;;"]
        if !get("Phone").isEmpty { lines.append("TEL;TYPE=CELL:" + esc(get("Phone"))) }
        if !get("Email").isEmpty { lines.append("EMAIL:" + esc(get("Email"))) }
        if !get("Company").isEmpty { lines.append("ORG:" + esc(get("Company"))) }
        if !get("Role").isEmpty { lines.append("TITLE:" + esc(get("Role"))) }
        if !get("Address").isEmpty { lines.append("ADR:;;" + esc(get("Address")) + ";;;;") }
        if !get("Website").isEmpty { lines.append("URL:" + esc(get("Website"))) }
        if !get("Birthday").isEmpty { lines.append("BDAY:" + esc(get("Birthday"))) }
        if !get("Notes").isEmpty { lines.append("NOTE:" + esc(get("Notes"))) }
        lines.append("END:VCARD")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent((name.isEmpty ? "Contact" : name).replacingOccurrences(of: "/", with: "-") + ".vcf")
        do {
            try lines.joined(separator: "\r\n").write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(file)
        } catch {
            NSSound.beep()
        }
    }
}

private struct PropertiesContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle

    var body: some View {
        let rows = FieldRows(c: $c)
        let fields = rows.fields
        VStack(alignment: .leading, spacing: 4) {
            if !c.args.isEmpty { TitleField(c: $c, s: s, prompt: "Properties") }
            ForEach(fields.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Field(prompt: "Property", text: rows.key(i), s: s, scale: 0.85, weight: .medium)
                        .foregroundStyle(s.faint)
                        .frame(width: 90, alignment: .leading)
                    Field(prompt: "Empty", text: rows.value(i), s: s, scale: 0.92, multiline: true)
                    RemoveButton(s: s) { rows.remove(i) }
                }
            }
            MiniButton(title: "Add a property", symbol: "plus", s: s) { rows.set(fields + [.init("Property", "")]) }
        }
    }
}

// MARK: - Tracking

private struct ProgressContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color

    var body: some View {
        let value = NoteComponents.number("value", in: c.body, fallback: 0)
        let total = max(1, NoteComponents.number("total", in: c.body, fallback: 10))
        let fraction = value / total
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TitleField(c: $c, s: s, prompt: "What's in progress?")
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(s.font(0.95, .bold).monospacedDigit())
                    .foregroundStyle(accent)
            }
            Bar(fraction: fraction, color: accent, height: 8)
            HStack(spacing: 6) {
                stepper(value: value, total: total)
                Spacer(minLength: 4)
                Text("of").font(s.font(0.8)).foregroundStyle(s.faint)
                Field(prompt: "10", text: Binding(get: { NoteComponents.format(total) }, set: { new in
                    if let n = NoteComponents.number(new), n > 0 { c.body = NoteComponents.setting("total", NoteComponents.format(n), in: c.body) }
                }), s: s, scale: 0.85, weight: .semibold)
                .frame(width: 48)
            }
        }
    }

    private func stepper(value: Double, total: Double) -> some View {
        HStack(spacing: 4) {
            MiniButton(title: "", symbol: "minus", s: s) { set(max(0, value - 1)) }
            Text(NoteComponents.format(value))
                .font(s.font(0.95, .semibold).monospacedDigit())
                .foregroundStyle(s.ink)
                .frame(minWidth: 26)
            MiniButton(title: "", symbol: "plus", s: s, tint: accent) { set(min(total, value + 1)) }
            if value < total {
                MiniButton(title: "Done", symbol: "checkmark", s: s) { set(total) }
            }
        }
    }

    private func set(_ v: Double) {
        withAnimation { c.body = NoteComponents.setting("value", NoteComponents.format(v), in: c.body) }
    }
}

private struct CounterContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color

    var body: some View {
        let count = NoteComponents.number("count", in: c.body, fallback: 0)
        let step = NoteComponents.number("step", in: c.body, fallback: 1)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                TitleField(c: $c, s: s, prompt: "What are you counting?")
                Text(NoteComponents.format(count))
                    .font(.system(size: s.size * 2.2, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            round("minus", tint: s.ink.opacity(0.5)) { set(count - step) }
            round("plus", tint: accent) { set(count + step) }
        }
        .contextMenu {
            Button("Back to 0") { set(0) }
            Menu("Count in steps of") {
                ForEach([1.0, 2, 5, 10, 0.5], id: \.self) { n in
                    Button(NoteComponents.format(n)) { c.body = NoteComponents.setting("step", NoteComponents.format(n), in: c.body) }
                }
            }
        }
    }

    private func round(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: s.size, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: s.size * 2.3, height: s.size * 2.3)
                .background(Circle().fill(tint))
        }
        .buttonStyle(PressStyle())
    }

    private func set(_ v: Double) {
        withAnimation { c.body = NoteComponents.setting("count", NoteComponents.format(v), in: c.body) }
    }
}

private struct RatingContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle

    var body: some View {
        let rating = Int(NoteComponents.number("rating", in: c.body, fallback: 0).rounded())
        let of = min(10, max(3, Int(NoteComponents.number("of", in: c.body, fallback: 5))))
        HStack(spacing: 8) {
            TitleField(c: $c, s: s, prompt: "What's rated?")
            HStack(spacing: 2) {
                ForEach(1...of, id: \.self) { n in
                    Button {
                        let new = n == rating ? 0 : n
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                            c.body = NoteComponents.setting("rating", "\(new)", in: c.body)
                        }
                    } label: {
                        Image(systemName: n <= rating ? "star.fill" : "star")
                            .font(.system(size: s.size * 1.15))
                            .foregroundStyle(n <= rating ? Color(red: 0.98, green: 0.7, blue: 0.1) : s.ink.opacity(0.25))
                            .scaleEffect(n == rating ? 1.12 : 1)
                    }
                    .buttonStyle(.plain)
                    .help("\(n) of \(of)")
                }
            }
            .fixedSize()
        }
    }
}

private struct CountdownContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color

    var body: some View {
        let cal = Calendar.current
        let raw = NoteComponents.value("date", in: c.body) ?? ""
        let date = NoteComponents.date(raw, calendar: cal)
        VStack(alignment: .leading, spacing: 4) {
            TitleField(c: $c, s: s, prompt: "What's coming?")
            if let date {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let span = NoteComponents.span(from: Date(), to: date)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(span.text)
                            .font(.system(size: s.size * 1.8, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(span.past ? s.faint : accent)
                        Text(span.text == "now" ? "" : span.past ? "ago" : "to go")
                            .font(s.font(0.9, .medium))
                            .foregroundStyle(s.faint)
                    }
                }
            } else {
                Text(raw.isEmpty ? "Pick a date" : "\u{201C}\(raw)\u{201D} isn't a date (2026-12-25, or 2026-12-25 09:30)")
                    .font(s.font(0.8))
                    .foregroundStyle(.orange)
            }
            DatePicker("", selection: Binding(get: { date ?? Date() }, set: { new in
                let hasTime = cal.component(.hour, from: new) != 0 || cal.component(.minute, from: new) != 0
                c.body = NoteComponents.setting("date", NoteComponents.dateString(new, calendar: cal, time: hasTime), in: c.body)
            }), displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
            .datePickerStyle(.compact)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

private struct HabitContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color
    static let weeks = 5

    var body: some View {
        let cal = Calendar.current
        let days = NoteComponents.habitDays(c.body)
        let today = cal.startOfDay(for: Date())
        let todayKey = NoteComponents.dateString(today, calendar: cal, time: false)
        let streak = NoteComponents.streak(days, now: Date(), calendar: cal)
        // The grid: whole weeks, ending with this one, Monday at the top.
        let weekday = (cal.component(.weekday, from: today) + 5) % 7
        let start = cal.date(byAdding: .day, value: -(weekday + 7 * (Self.weeks - 1)), to: today) ?? today
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TitleField(c: $c, s: s, prompt: "Habit")
                Label("\(streak) day\(streak == 1 ? "" : "s")", systemImage: "flame.fill")
                    .font(s.font(0.85, .bold).monospacedDigit())
                    .foregroundStyle(streak > 0 ? Color.orange : s.faint)
                    .help("Days in a row")
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<Self.weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: w * 7 + d, to: start) ?? today
                            let key = NoteComponents.dateString(day, calendar: cal, time: false)
                            let on = days.contains(key)
                            let future = day > today
                            Button { toggle(key, days) } label: {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(on ? accent : s.ink.opacity(future ? 0.03 : 0.08))
                                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(key == todayKey ? accent : .clear, lineWidth: 1.5))
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(.plain)
                            .disabled(future)
                            .help(day.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 6) {
                    MiniButton(title: days.contains(todayKey) ? "Done today" : "Tick today",
                               symbol: days.contains(todayKey) ? "checkmark.circle.fill" : "circle", s: s,
                               tint: days.contains(todayKey) ? accent : nil) { toggle(todayKey, days) }
                    Text("\(days.count) in all").font(s.font(0.75)).foregroundStyle(s.faint)
                }
            }
        }
    }

    private func toggle(_ key: String, _ days: Set<String>) {
        var d = days
        if d.contains(key) { d.remove(key) } else { d.insert(key) }
        withAnimation(.easeInOut(duration: 0.12)) { c.body = NoteComponents.habitBody(d) }
    }
}

private struct CalcContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color
    @FocusState private var focused: Int?

    var body: some View {
        let results = NoteComponents.calc(c.body)
        VStack(alignment: .leading, spacing: 3) {
            if !c.args.isEmpty { TitleField(c: $c, s: s, prompt: "Calculator") }
            ForEach(c.body.indices, id: \.self) { i in
                let r = results[safe: i]
                let isTotal = ["total", "sum"].contains(c.body[i].trimmingCharacters(in: .whitespaces).lowercased())
                HStack(spacing: 8) {
                    Field(prompt: "1200 * 12, or rent = 1200", text: Binding(get: { self.c.body[safe: i] ?? "" }, set: { new in
                        guard self.c.body.indices.contains(i) else { return }
                        c.body[i] = new
                    }), s: s, scale: 0.92, weight: isTotal ? .bold : .regular, mono: true)
                    .focused($focused, equals: i)
                    .onSubmit {
                        c.body.insert("", at: min(i + 1, c.body.count))
                        focused = i + 1
                    }
                    if let v = r?.value {
                        Text(NoteComponents.format(v))
                            .font(s.font(0.92, isTotal ? .bold : .semibold, mono: true))
                            .foregroundStyle(isTotal ? accent : s.ink.opacity(0.7))
                            .textSelection(.enabled)
                    } else if let e = r?.error {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .help(e)
                    }
                }
                .padding(.vertical, 1)
                .overlay(alignment: .top) {
                    if isTotal { Rectangle().fill(s.ink.opacity(0.15)).frame(height: 0.5).offset(y: -2) }
                }
            }
            MiniButton(title: "Line", symbol: "plus", s: s) {
                c.body.append("")
                focused = c.body.count - 1
            }
        }
    }
}

// MARK: - Text & layout

private struct CalloutContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle

    static let styles: [(key: String, symbol: String, color: Color)] = [
        ("info", "info.circle.fill", Color(red: 0.2, green: 0.5, blue: 0.95)),
        ("tip", "lightbulb.fill", Color(red: 0.95, green: 0.68, blue: 0.1)),
        ("idea", "sparkles", Color(red: 0.6, green: 0.35, blue: 0.95)),
        ("success", "checkmark.seal.fill", Color(red: 0.15, green: 0.62, blue: 0.35)),
        ("warning", "exclamationmark.triangle.fill", Color(red: 0.95, green: 0.5, blue: 0.1)),
        ("danger", "xmark.octagon.fill", Color(red: 0.88, green: 0.22, blue: 0.25)),
    ]

    var body: some View {
        let key = c.args.lowercased()
        let look = Self.styles.first { $0.key == key } ?? Self.styles[0]
        HStack(alignment: .top, spacing: 8) {
            Menu {
                ForEach(Self.styles, id: \.key) { st in
                    Button(st.key.capitalized) { c.args = st.key }
                }
            } label: {
                Image(systemName: look.symbol)
                    .font(.system(size: s.size * 1.1))
                    .foregroundStyle(look.color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change its look")
            Field(prompt: "Write something to stand out", text: $c.bodyText, s: s, multiline: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(look.color.opacity(0.13)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(look.color).frame(width: 3).padding(.vertical, 4)
        }
    }
}

private struct QuoteContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color

    var body: some View {
        let q = NoteComponents.quote(c.body)
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Field(prompt: "What was said", text: Binding(get: { NoteComponents.quote(self.c.body).text }, set: { new in
                    c.body = NoteComponents.quoteBody(text: new, author: NoteComponents.quote(self.c.body).author)
                }), s: s, scale: 1.05, multiline: true)
                .italic()
                HStack(spacing: 2) {
                    Text("—").foregroundStyle(s.faint)
                    Field(prompt: "Who said it", text: Binding(get: { NoteComponents.quote(self.c.body).author }, set: { new in
                        c.body = NoteComponents.quoteBody(text: NoteComponents.quote(self.c.body).text, author: new)
                    }), s: s, scale: 0.85, weight: .medium)
                }
                .font(s.font(0.85))
            }
            .opacity(q.text.isEmpty && q.author.isEmpty ? 0.8 : 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CodeContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Field(prompt: "language", text: $c.args, s: s, scale: 0.75, weight: .semibold, mono: true)
                    .frame(maxWidth: 120)
                Spacer()
                MiniButton(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc", s: s) {
                    Clipboard.copy(c.bodyText)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                }
            }
            Field(prompt: "Code", text: $c.bodyText, s: s, scale: 0.88, mono: true, multiline: true)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(s.ink.opacity(0.07)))
        }
    }
}

private struct ToggleContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: s.size * 0.75, weight: .bold))
                        .foregroundStyle(s.ink.opacity(0.6))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Close" : "Open")
                TitleField(c: $c, s: s, prompt: "Heading")
                if !open, !c.bodyText.isEmpty {
                    Text("\(c.body.count) line\(c.body.count == 1 ? "" : "s")").font(s.font(0.72)).foregroundStyle(s.faint)
                }
            }
            if open {
                Field(prompt: "What's under it", text: $c.bodyText, s: s, multiline: true)
                    .padding(.leading, 22)
                    .transition(.opacity)
            }
        }
    }
}

private struct DividerContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    @State private var hover = false

    var body: some View {
        let style = c.args.lowercased()
        let known = NoteComponents.dividerStyles.contains(style)
        HStack(spacing: 8) {
            line(style)
            if !known, !c.args.isEmpty {
                Text(c.args)
                    .font(s.font(0.8, .semibold))
                    .foregroundStyle(s.faint)
                    .textCase(.uppercase)
                    .fixedSize()
                line(style)
            }
            if hover {
                Menu {
                    Button("Plain") { c.args = "" }
                    ForEach(NoteComponents.dividerStyles, id: \.self) { st in Button(st.capitalized) { c.args = st } }
                    Divider()
                    Button("With a heading…") { c.args = "Section" }
                } label: {
                    Image(systemName: "paintbrush").font(.system(size: 9, weight: .semibold)).foregroundStyle(s.faint)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Its look: plain, dashed, dotted, thick, double, or a heading in the middle (edit it as text to change the words)")
                .padding(.trailing, 24)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder private func line(_ style: String) -> some View {
        switch style {
        case "dashed", "dotted":
            Line()
                .stroke(s.ink.opacity(0.3), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: style == "dashed" ? [6, 4] : [0.5, 4]))
                .frame(height: 2)
        case "thick":
            Capsule().fill(s.ink.opacity(0.25)).frame(height: 3)
        case "double":
            VStack(spacing: 2) {
                Rectangle().fill(s.ink.opacity(0.22)).frame(height: 1)
                Rectangle().fill(s.ink.opacity(0.22)).frame(height: 1)
            }
        default:
            Rectangle().fill(s.ink.opacity(0.18)).frame(height: 1)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

/// Text side by side, a line down between: each column written in as the note is (Return makes a
/// new line, links are links), as tall as the tallest.
private struct ColumnsContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    @State private var hover = false

    private var columns: [String] { NoteComponents.columns(c.body) }

    var body: some View {
        let cols = columns
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(cols.indices, id: \.self) { i in
                    if i > 0 {
                        Rectangle().fill(s.ink.opacity(0.2)).frame(width: 1).padding(.horizontal, 8)
                    }
                    BoxEditor(text: Binding(get: { self.columns[safe: i] ?? "" }, set: { new in
                        var all = self.columns
                        guard all.indices.contains(i) else { return }
                        all[i] = new
                        c.body = NoteComponents.columnsBody(all)
                    }), fontSize: s.size, ink: NSColor(s.ink), titleScale: 1, autoHeight: true, continuation: true, slashMenu: false)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .overlay(alignment: .topLeading) {
                        if (cols[safe: i] ?? "").isEmpty {
                            Text(i == 0 ? "Left" : i == cols.count - 1 ? "Right" : "Middle")
                                .font(s.font(0.9))
                                .foregroundStyle(s.ink.opacity(0.28))
                                .padding(.leading, 6)
                                .padding(.top, 2)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if hover {
                HStack(spacing: 6) {
                    if cols.count < NoteComponents.maxColumns {
                        MiniButton(title: "Column", symbol: "plus", s: s) { c.body = NoteComponents.columnsBody(self.columns + [""]) }
                    }
                    if cols.count > 2 {
                        MiniButton(title: "Last column", symbol: "minus", s: s) {
                            var all = self.columns
                            let gone = all.removeLast()
                            // What was in it goes on the end of the column before, not away.
                            if !gone.isEmpty { all[all.count - 1] += (all[all.count - 1].isEmpty ? "" : "\n") + gone }
                            c.body = NoteComponents.columnsBody(all)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Links & media

private struct BookmarkContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    @ObservedObject private var previews = LinkPreviews.shared

    var body: some View {
        let address = c.body.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? ""
        let link = BuiltinTool.webURL(address)
        VStack(alignment: .leading, spacing: 6) {
            if let link, address != "https://" {
                LinkLine(link: link, info: previews.info[link.absoluteString], loading: previews.isLoading(link))
                    .onAppear { previews.ensure(link) }
                    .onChange(of: link) { _, now in previews.ensure(now) }
            }
            HStack(spacing: 4) {
                Image(systemName: "link").font(.system(size: s.size * 0.7)).foregroundStyle(s.faint)
                Field(prompt: "https://…", text: Binding(get: { address }, set: { c.body = [$0] }), s: s, scale: 0.8)
                    .foregroundStyle(s.faint)
            }
        }
    }
}

private struct ImageContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle

    /// Pictures read from files, so a note isn't reading them again on every change.
    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        let source = c.body.first?.trimmingCharacters(in: .whitespaces) ?? ""
        VStack(alignment: .leading, spacing: 6) {
            picture(source)
            if !c.args.isEmpty || !source.isEmpty {
                Field(prompt: "Caption", text: $c.args, s: s, scale: 0.8)
                    .foregroundStyle(s.faint)
            }
            HStack(spacing: 6) {
                Field(prompt: "A picture's file or web address", text: Binding(get: { source }, set: { c.body = [$0] }), s: s, scale: 0.75)
                    .foregroundStyle(s.faint)
                MiniButton(title: "Choose…", symbol: "photo.on.rectangle", s: s) { choose() }
            }
        }
    }

    @ViewBuilder private func picture(_ source: String) -> some View {
        if source.hasPrefix("http://") || source.hasPrefix("https://"), let url = URL(string: source) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: placeholder("Couldn't load the picture")
                default: ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .frame(maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if !source.isEmpty {
            if let image = Self.image(source) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: Self.path(source))) }
                    .help("Double-click to open it")
            } else {
                placeholder("No picture at \u{201C}\(source)\u{201D}")
            }
        } else {
            placeholder("Choose a picture, or paste its address below")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Label(text, systemImage: "photo")
            .font(s.font(0.8))
            .foregroundStyle(s.faint)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(s.ink.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    static func path(_ source: String) -> String { (source as NSString).expandingTildeInPath }

    @MainActor static func image(_ source: String) -> NSImage? {
        let p = path(source)
        if let hit = cache[p] { return hit }
        guard let image = NSImage(contentsOfFile: p) else { return nil }
        if cache.count > 40 { cache.removeAll() }
        cache[p] = image
        return image
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        c.body = [p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p]
    }
}

private struct SnippetContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TitleField(c: $c, s: s, prompt: "Snippet")
                Button {
                    Clipboard.copy(c.bodyText)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(s.font(0.8, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(copied ? Color.green : accent))
                }
                .buttonStyle(PressStyle())
                .disabled(c.bodyText.isEmpty)
            }
            Field(prompt: "Text to copy again and again", text: $c.bodyText, s: s, scale: 0.92, multiline: true)
        }
    }
}

// MARK: - Runs things

private struct ActionContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color

    var body: some View {
        if let scheduler = NoteComponentServices.shared.scheduler {
            RunButton(c: $c, s: s, accent: accent, scheduler: scheduler)
        } else {
            Text("Actions aren't ready yet").font(s.font(0.8)).foregroundStyle(s.faint)
        }
    }

    private struct RunButton: View {
        @Binding var c: NoteComponent
        let s: ComponentStyle
        let accent: Color
        @ObservedObject var scheduler: Scheduler

        var body: some View {
            let action = scheduler.actions.actions.first { $0.name.lowercased() == c.args.lowercased() }
            let running = action.map { scheduler.runningActions.contains($0.id) } ?? false
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        guard let action else { return }
                        let given = NoteComponents.fields(c.body).map { ActionArgument(name: ActionArgument.clean($0.key), value: $0.value) }
                        scheduler.runAction(action.id, arguments: given)
                    } label: {
                        Label(running ? "Running…" : (action?.name ?? "Pick an action"), systemImage: action?.symbol ?? "bolt.circle")
                            .font(s.font(0.95, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: s.size * 2.1)
                            .background(Capsule().fill(action == nil ? Color.gray : accent))
                    }
                    .buttonStyle(PressStyle())
                    .disabled(action == nil || running)
                    .help(action.map { "Run \u{201C}\($0.name)\u{201D}: \($0.summary)" } ?? "Pick which action it runs")
                    Menu {
                        ForEach(scheduler.actions.actions) { a in
                            Button(a.name) {
                                c.args = a.name
                                c.body = NoteComponents.fieldsBody(a.parameters.filter { !$0.name.isEmpty }.map { .init($0.name, "") })
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick the action")
                    if let action {
                        Button { ActionsWindow.show(scheduler, select: action.id) } label: {
                            Image(systemName: "arrow.up.forward.square").foregroundStyle(s.faint)
                        }
                        .buttonStyle(.plain)
                        .help("Open it in Actions")
                    }
                }
                if let action, !action.parameters.filter({ !$0.name.isEmpty }).isEmpty {
                    ForEach(action.parameters.filter { !$0.name.isEmpty }, id: \.name) { p in
                        HStack(spacing: 6) {
                            Text(p.name).font(s.font(0.8, .medium, mono: true)).foregroundStyle(s.faint).frame(width: 80, alignment: .leading)
                            Field(prompt: p.value.isEmpty ? "(empty)" : p.value, text: Binding(get: {
                                NoteComponents.value(p.name, in: c.body) ?? ""
                            }, set: { new in
                                c.body = NoteComponents.setting(p.name, new, in: c.body)
                            }), s: s, scale: 0.85)
                        }
                    }
                }
                if let action, let last = scheduler.actionResults[action.id] {
                    Label(last.output, systemImage: last.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(s.font(0.78))
                        .foregroundStyle(last.ok ? s.faint : Color.orange)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct ShortcutContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle
    let accent: Color
    @State private var names: [String] = []
    @State private var running = false
    @State private var output: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: run) {
                    Label(running ? "Running…" : (c.args.isEmpty ? "Pick a shortcut" : c.args), systemImage: "bolt.horizontal.circle.fill")
                        .font(s.font(0.95, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: s.size * 2.1)
                        .background(Capsule().fill(c.args.isEmpty ? Color.gray : accent))
                }
                .buttonStyle(PressStyle())
                .disabled(c.args.isEmpty || running)
                Menu {
                    if names.isEmpty { Text("No shortcuts found") }
                    ForEach(names, id: \.self) { n in Button(n) { c.args = n } }
                } label: {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pick the shortcut")
            }
            Field(prompt: "What it's given (optional)", text: $c.bodyText, s: s, scale: 0.85, multiline: true)
            if let output {
                Text(output.text)
                    .font(s.font(0.82))
                    .foregroundStyle(output.ok ? s.ink.opacity(0.75) : Color.orange)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(s.ink.opacity(0.05)))
            }
        }
        .task { if names.isEmpty { names = (try? await ShortcutRunner.list()) ?? [] } }
    }

    private func run() {
        let name = c.args
        let input = c.bodyText
        running = true
        Task { @MainActor in
            do {
                let out = try await ShortcutRunner.run(name, input: input, returnsText: true)
                output = (true, out.isEmpty ? "\(name) ran." : out)
            } catch {
                output = (false, "\(name) failed: \(error.localizedDescription)")
            }
            running = false
        }
    }
}

private struct UnknownContent: View {
    @Binding var c: NoteComponent
    let s: ComponentStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\u{201C}\(c.kind)\u{201D}: a component this version doesn't know (kept as it is)", systemImage: "questionmark.square.dashed")
                .font(s.font(0.78, .medium))
                .foregroundStyle(s.faint)
            Text(c.bodyText)
                .font(s.font(0.88, mono: true))
                .foregroundStyle(s.ink)
                .textSelection(.enabled)
        }
    }
}
