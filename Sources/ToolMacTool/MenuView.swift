import AppKit
import SwiftUI

/// The panel that drops down from the menu bar icon.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tools").font(.headline)
                Spacer()
                Text("v\(Updater.currentVersion)" + (Updater.currentCommit.map { " · \($0.prefix(7))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(Tools.all) { tool in
                    ToolRow(tool: tool, running: model.running.contains(tool.id), result: model.results[tool.id]) {
                        model.run(tool)
                    }
                }
            }
            .padding(.horizontal, 6)

            Divider().padding(.vertical, 6)
            UpdateRow(updater: updater).padding(.horizontal, 6)

            Divider().padding(.vertical, 6)
            VStack(spacing: 2) {
                Toggle(isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) })) {
                    Text("Open at login")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                MenuButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .frame(width: 340)
    }
}

struct ToolRow: View {
    let tool: Tool
    let running: Bool
    let result: AppModel.Result?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.gradient)
                    if running {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: tool.symbol).foregroundStyle(.white)
                    }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title).fontWeight(.medium)
                    Text(tool.subtitle).font(.caption).foregroundStyle(.secondary)
                    if let result {
                        HStack(spacing: 4) {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.ok ? .green : .orange)
                            Text(result.message).lineLimit(3)
                        }
                        .font(.caption)
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(running)
        .onHover { hover = $0 }
    }
}

struct UpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.state {
        case .available(let update):
            MenuButton(title: update.release.map { "Update to \($0.tag)" } ?? "Update (build \(update.commit.short) here)",
                       symbol: "arrow.down.circle.fill", detail: update.commit.title, tint: .accentColor) {
                updater.install()
            }
        case .installing(let step):
            MenuButton(title: step, symbol: "arrow.triangle.2.circlepath", busy: true) {}
        case .checking:
            MenuButton(title: "Checking for updates…", symbol: "arrow.clockwise", busy: true) {}
        case .upToDate:
            MenuButton(title: "Check for updates", symbol: "arrow.clockwise", detail: "Up to date") {
                updater.check(userInitiated: true)
            }
        case .failed(let why):
            MenuButton(title: "Check for updates", symbol: "arrow.clockwise", detail: why) {
                updater.check(userInitiated: true)
            }
        case .idle:
            MenuButton(title: "Check for updates", symbol: "arrow.clockwise") { updater.check(userInitiated: true) }
        }
    }
}

/// A plain, full-width menu line with a hover highlight.
struct MenuButton: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var tint: Color = .primary
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if busy { ProgressView().controlSize(.mini) } else { Image(systemName: symbol).foregroundStyle(tint) }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hover && !busy ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hover = $0 }
    }
}
