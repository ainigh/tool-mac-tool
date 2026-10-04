import AppKit
import SwiftUI
import ToolCore

/// The timers' log, kept on disk, with what watches it: the thresholds (a card the moment one is
/// crossed) and the signals sent to a web address (kept and retried until they get through).
@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var log: ActivityLog
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

    static let device = Host.current().localizedName ?? "Mac"

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

    /// Adds to the log; then the thresholds it crosses come up, and what's sent goes out.
    func record(_ kind: LogEntry.Kind, source: String, name: String, detail: String = "", value: Double? = nil, at: Date = Date()) {
        let entry = LogEntry(at: at, source: source, name: name, kind: kind, detail: detail, value: value)
        log.add(entry)
        scheduleSave()
        if settings.sends(kind) { send(Signal(entry: entry, calendar: calendar, device: Self.device)) }
        for crossing in ThresholdRule.crossed(by: entry, rules: settings.rules, log: log, calendar: calendar) {
            let text = "\(crossing.count) \(crossing.rule.metric.words.lowercased()) today"
            let note = LogEntry(at: at, source: "thresholds", name: "Thresholds", kind: .threshold,
                                detail: "\(crossing.rule.describe): \(text)", value: Double(crossing.count))
            log.add(note)
            if settings.sends(.threshold) {
                send(Signal(entry: note, calendar: calendar, device: Self.device, threshold: crossing))
            }
            ThresholdCard.show(rule: crossing.rule, count: crossing.count)
        }
    }

    func clearLog() {
        log = ActivityLog()
        scheduleSave()
    }

    // MARK: Signals

    private func send(_ signal: Signal) {
        guard settings.endpoint != nil else { return }
        outbox.append(signal)
        if outbox.count > Self.outboxLimit { outbox.removeFirst(outbox.count - Self.outboxLimit) }
        saveOutbox()
        flush()
    }

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

    /// A test signal, sent straight away (not kept if it fails).
    func sendTest() {
        guard let url = settings.endpoint else {
            lastSend = "Add an http(s) address first"
            return
        }
        let entry = LogEntry(at: Date(), source: "test", name: "Test", kind: .alarm, detail: "A test from Tool Mac Tool")
        let signal = Signal(entry: entry, calendar: calendar, device: Self.device)
        lastSend = "Sending a test…"
        let secret = settings.secret
        Task {
            switch await Self.post(signal, to: url, secret: secret) {
            case .sent: self.lastSend = "Test sent · it worked"
            case .refused(let why), .failed(let why): self.lastSend = "Test failed: \(why)"
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
            request.httpBody = try signal.json()
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return .sent }
            if (400..<500).contains(code) && code != 408 && code != 429 { return .refused("HTTP \(code)") }
            return .failed("HTTP \(code)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// What a signal looks like, for writing the worker that takes them.
    var sample: String {
        let rule = settings.rules.first ?? ThresholdRule(metric: .snoozes, limit: 4)
        let entry = LogEntry(at: Date(), source: "thresholds", name: "Thresholds", kind: .threshold,
                             detail: "\(rule.describe): \(rule.limit + 1) \(rule.metric.words.lowercased()) today",
                             value: Double(rule.limit + 1))
        let signal = Signal(entry: entry, calendar: calendar, device: Self.device, threshold: (rule, rule.limit + 1))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(signal)).map { String(decoding: $0, as: UTF8.self) } ?? ""
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
