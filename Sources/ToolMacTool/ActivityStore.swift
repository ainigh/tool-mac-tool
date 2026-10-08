import AppKit
import SwiftUI
import ToolCore

/// The timers' log, kept on disk, and who's told of each entry as it goes in: the scheduler, whose
/// event jobs wait for alarms, the battery and a day's counts (the thresholds and signals that
/// used to live here are schedules now). Signals still waiting from before that are sent on.
@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var log: ActivityLog
    /// The thresholds and signals as they were set before they became schedules (read once, to
    /// turn them into schedules; its address still takes the signals left waiting).
    @Published var settings: SignalSettings {
        didSet {
            if settings != oldValue {
                saveSettings()
                if settings.endpoint != oldValue.endpoint { flush() }
            }
        }
    }
    /// Signals waiting to go out (the address didn't answer), oldest first.
    @Published private(set) var outbox: [Signal] = []
    /// How the last send went, in words.
    @Published private(set) var lastSend: String?
    @Published private(set) var sending = false

    let logURL = ActivityLog.defaultURL()
    private let settingsURL = ActivityLog.defaultURL().deletingLastPathComponent().appendingPathComponent("timer-signals.json")
    private let outboxURL = ActivityLog.defaultURL().deletingLastPathComponent().appendingPathComponent("timer-outbox.json")
    private var saveTask: Task<Void, Never>?
    private var retry: Timer?
    /// Signals kept at most (the oldest go first).
    static let outboxLimit = 500

    /// What's sent for "which Mac": never its name or its model, only this.
    static let device = Signal.anonymousDevice

    init() {
        log = ActivityLog.load(from: ActivityLog.defaultURL()) ?? ActivityLog()
        let dir = ActivityLog.defaultURL().deletingLastPathComponent()
        settings = (try? Data(contentsOf: dir.appendingPathComponent("timer-signals.json")))
            .flatMap { try? JSONDecoder().decode(SignalSettings.self, from: $0) } ?? SignalSettings()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        outbox = (try? Data(contentsOf: dir.appendingPathComponent("timer-outbox.json")))
            .flatMap { try? decoder.decode([Signal].self, from: $0) } ?? []
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        RunLoop.main.add(t, forMode: .common)
        retry = t
        flush()
    }

    var calendar: Calendar { Scheduler.calendar(Preferences.shared.settings) }

    /// Told of every entry once it's in the log.
    private var listeners: [(LogEntry) -> Void] = []

    func onRecord(_ listener: @escaping (LogEntry) -> Void) { listeners.append(listener) }

    /// Adds to the log; then everyone listening hears of it (the scheduler's event jobs).
    @discardableResult
    func record(_ kind: LogEntry.Kind, source: String, name: String, detail: String = "", value: Double? = nil,
                at: Date = AppClock.now()) -> LogEntry {
        let entry = LogEntry(at: at, source: source, name: name, kind: kind, detail: detail, value: value)
        log.add(entry)
        scheduleSave()
        for listener in listeners { listener(entry) }
        return entry
    }

    /// Test mode ended: what was logged on the fast clock (dated after the real time) goes.
    func dropFuture(after now: Date = Date()) {
        let kept = log.entries.filter { $0.at <= now.addingTimeInterval(5) }
        guard kept.count != log.entries.count else { return }
        log = ActivityLog(entries: kept)
        scheduleSave()
    }

    func clearLog() {
        log = ActivityLog()
        scheduleSave()
    }

    // MARK: Signals left from before (sent on, then this is quiet)

    /// Sends what's waiting, one at a time, oldest first. A refusal (4xx) drops that signal; no
    /// answer or a server error keeps it for the next try (every minute).
    func flush() {
        guard !sending, let url = settings.endpoint, let first = outbox.first else { return }
        sending = true
        let secret = settings.secret
        Task {
            let result = await Self.post(first, to: url, secret: secret)
            self.sending = false
            switch result {
            case .sent:
                self.lastSend = "Sent \(first.type) · \(Date().formatted(date: .omitted, time: .shortened))"
                self.outbox.removeAll { $0.id == first.id }
                self.saveOutbox()
                self.flush()
            case .refused(let why):
                self.lastSend = "Refused (\(why)): dropped one \(first.type) signal"
                self.outbox.removeAll { $0.id == first.id }
                self.saveOutbox()
                self.flush()
            case .failed(let why):
                self.lastSend = "Couldn't send (\(why)): will try again"
            }
        }
    }

    enum PostResult { case sent, refused(String), failed(String) }

    nonisolated static func post(_ signal: Signal, to url: URL, secret: String) async -> PostResult {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ToolMacTool", forHTTPHeaderField: "User-Agent")
        let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            // One queued by an older version may still carry the Mac's name.
            var sent = signal
            sent.device = Signal.anonymousDevice
            request.httpBody = try sent.json()
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return .sent }
            if (400..<500).contains(code) && code != 408 && code != 429 { return .refused("HTTP \(code)") }
            return .failed("HTTP \(code)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            try? self.log.save(to: self.logURL)
        }
    }

    private func saveSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    private func saveOutbox() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: outboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(outbox).write(to: outboxURL, options: .atomic)
    }
}
