import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import SwiftUI
import ToolCore

// Record screen: drag a box on the screen, and what's inside it is recorded (with the microphone,
// or without any sound) to an .mp4 in the Glass folder, with Pause and Stop on a small bar beside
// the box. This app's own windows (the bar, the box's frame) are left out of the video.

/// One screen recording at a time: picking the box, recording it, the bar and the frame.
@MainActor
final class ScreenRecorder: ObservableObject {
    enum State: Equatable { case idle, picking, starting, recording, paused, saving }

    @Published private(set) var state = State.idle
    /// Seconds recorded so far (pauses left out).
    @Published private(set) var elapsed = 0.0
    @Published private(set) var withAudio = true
    /// Called with each recording that was saved.
    var onSaved: ((URL) -> Void)?

    private var capture: ScreenCapture?
    private var picker: RegionPicker?
    private var frame: NSWindow?
    private var bar: NSPanel?
    private var ticker: Timer?
    private var runningSince: Date?
    private var banked = 0.0

    var busy: Bool { state != .idle }

    /// The tile: choose a box, then record it. While recording, it brings the bar forward instead.
    func begin(audio: Bool) {
        guard state == .idle else {
            bar?.orderFrontRegardless()
            return
        }
        withAudio = audio
        guard Self.mayCapture() else { return }
        let go = { [weak self] in
            guard let self else { return }
            self.state = .picking
            // A moment for the menu bar's panel to go away first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let picker = RegionPicker { [weak self] picked in
                    guard let self else { return }
                    self.picker = nil
                    if let picked { self.start(picked.rect, on: picked.screen) } else { self.state = .idle }
                }
                self.picker = picker
                picker.show()
            }
        }
        if audio {
            Listener.authorize { problem in
                if let problem {
                    HUD.shared.show(title: "Can't record your voice", message: problem, ok: false, reveal: nil)
                    VoiceProblem.openPrivacy(problem)
                } else {
                    go()
                }
            }
        } else {
            go()
        }
    }

    /// Screen Recording is allowed; if not, macOS is asked (the first time it shows its own
    /// prompt) and its settings page is opened.
    static func mayCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !CGRequestScreenCaptureAccess() {
            HUD.shared.show(title: "Screen Recording is off",
                            message: "Turn on Tool Mac Tool in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. macOS may ask you to reopen the app.",
                            ok: false, reveal: nil)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
        return true
    }

    private func start(_ rect: CGRect, on screen: NSScreen) {
        state = .starting
        let kind: Recordings.Kind = withAudio ? .screen : .screenOnly
        let folder = GlassWindow.glassFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let capture = ScreenCapture(url: Recordings.newURL(kind, folder: folder), audio: withAudio)
        self.capture = capture
        capture.onFailed = { [weak self] problem in self?.failed(problem) }
        showFrame(around: rect)
        Task { @MainActor in
            do {
                try await capture.start(region: rect, screen: screen)
                guard self.capture === capture else { return }
                self.state = .recording
                self.elapsed = 0
                self.banked = 0
                self.runningSince = Date()
                self.ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                self.showBar(near: rect, on: screen)
            } catch {
                self.capture = nil
                self.tearDown()
                self.state = .idle
                HUD.shared.show(title: "Couldn't start recording", message: error.localizedDescription, ok: false, reveal: nil)
            }
        }
    }

    func pause() {
        guard state == .recording else { return }
        capture?.pause()
        if let runningSince { banked += Date().timeIntervalSince(runningSince) }
        runningSince = nil
        state = .paused
        tick()
    }

    func resume() {
        guard state == .paused else { return }
        capture?.resume()
        runningSince = Date()
        state = .recording
    }

    /// Stops and saves.
    func stop() {
        guard state == .recording || state == .paused, let capture else { return }
        state = .saving
        ticker?.invalidate()
        capture.stop { [weak self] url, problem in
            guard let self else { return }
            self.capture = nil
            self.tearDown()
            self.state = .idle
            if let url {
                HUD.shared.show(title: "Recording saved", message: url.lastPathComponent, ok: true, reveal: url)
                self.onSaved?(url)
            } else {
                HUD.shared.show(title: "Couldn't save the recording", message: problem ?? "Nothing was recorded",
                                ok: false, reveal: nil)
            }
        }
    }

    /// Stops and throws the recording away.
    func discard() {
        guard state == .recording || state == .paused, let capture else { return }
        state = .saving
        ticker?.invalidate()
        capture.stop { [weak self] url, _ in
            if let url { try? FileManager.default.removeItem(at: url) }
            guard let self else { return }
            self.capture = nil
            self.tearDown()
            self.state = .idle
        }
    }

    /// The capture stopped by itself (macOS stopped it, or the file couldn't be written): keep
    /// what was recorded.
    private func failed(_ problem: String) {
        guard capture != nil, state == .recording || state == .paused else { return }
        NSLog("screen recording stopped: \(problem)")
        stop()
    }

    private func tick() {
        elapsed = banked + (runningSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func tearDown() {
        ticker?.invalidate()
        ticker = nil
        runningSince = nil
        frame?.orderOut(nil)
        frame = nil
        bar?.orderOut(nil)
        bar = nil
    }

    // MARK: The frame around the box, and the bar

    private func showFrame(around rect: CGRect) {
        let pad: CGFloat = 4
        let w = NSPanel(contentRect: rect.insetBy(dx: -pad, dy: -pad), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: RecordingFrame(recorder: self))
        w.orderFrontRegardless()
        frame = w
    }

    private func showBar(near rect: CGRect, on screen: NSScreen) {
        let host = FirstClickHostingView(rootView: RecordingBar(recorder: self))
        let size = host.fittingSize
        let visible = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < visible.minY + 8 { origin.y = rect.maxY + 12 }                    // no room below: above
        if origin.y + size.height > visible.maxY - 8 { origin.y = rect.minY + 16 }      // nor above: inside
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        let p = BarPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = host
        p.orderFrontRegardless()
        bar = p
    }
}

/// The bar's panel: it never takes the keyboard from the app being recorded.
private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// The frame drawn just outside the box being recorded (left out of the video).
struct RecordingFrame: View {
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        let paused = recorder.state == .paused
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: paused ? [6, 5] : []))
            .foregroundStyle(paused ? Color.white.opacity(0.8) : Color(red: 1, green: 0.3, blue: 0.35))
            .shadow(color: .black.opacity(0.35), radius: 2)
            .padding(1)
    }
}

/// The bar beside the box: a light, the time, Pause or Resume, Stop, and throw it away.
struct RecordingBar: View {
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        let paused = recorder.state == .paused
        HStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1 / 15, paused: paused)) { t in
                let pulse = paused ? 0 : (1 + sin(t.date.timeIntervalSinceReferenceDate * 4)) / 2
                Circle()
                    .fill(paused ? Color.white.opacity(0.5) : Color(red: 1, green: 0.3, blue: 0.35))
                    .frame(width: 10, height: 10)
                    .opacity(0.55 + 0.45 * pulse)
            }
            .frame(width: 10, height: 10)
            Text(Captions.clock(recorder.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 40, alignment: .leading)
            Image(systemName: recorder.withAudio ? "mic.fill" : "mic.slash")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .help(recorder.withAudio ? "Recording the microphone too" : "No sound")
            GlassIcon(symbol: paused ? "play.fill" : "pause.fill", help: paused ? "Resume" : "Pause") {
                paused ? recorder.resume() : recorder.pause()
            }
            .disabled(recorder.state == .saving)
            PillButton(title: recorder.state == .saving ? "Saving…" : "Stop", prominent: true) { recorder.stop() }
                .disabled(recorder.state == .saving)
            GlassIcon(symbol: "trash", help: "Stop and throw this recording away") { recorder.discard() }
                .disabled(recorder.state == .saving)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
        .padding(4)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Choosing the box

/// Dims every screen and lets you drag a box on one of them. A click without dragging takes that
/// whole screen; Esc cancels.
@MainActor
final class RegionPicker {
    private var windows: [NSWindow] = []
    private let done: ((rect: CGRect, screen: NSScreen)?) -> Void
    private var finished = false
    /// What it says before a box is dragged.
    private let hint: String

    init(hint: String = "Drag a box around what to record  ·  click for the whole screen  ·  Esc to cancel",
         done: @escaping ((rect: CGRect, screen: NSScreen)?) -> Void) {
        self.hint = hint
        self.done = done
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let w = PickerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.hint = hint
            view.picked = { [weak self, weak w] local in
                guard let self, let w else { return }
                self.finish((rect: w.convertToScreen(local), screen: screen))
            }
            view.cancelled = { [weak self] in self?.finish(nil) }
            w.contentView = view
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w)
        }
        let mouse = NSEvent.mouseLocation
        let key = windows.first { $0.frame.contains(mouse) } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
        if let view = key?.contentView { key?.makeFirstResponder(view) }
    }

    private func finish(_ result: (rect: CGRect, screen: NSScreen)?) {
        guard !finished else { return }
        finished = true
        for w in windows { w.orderOut(nil) }
        windows = []
        // Let the dimming leave the screen before the first frame is taken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.done(result) }
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One screen's dimming: drag a box (it's cut out of the dimming, with its size beside it).
private final class PickerView: NSView {
    var picked: ((NSRect) -> Void)?
    var cancelled: (() -> Void)?
    var hint = ""
    private var start: NSPoint?
    private var box: NSRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        start = convert(event.locationInWindow, from: nil)
        box = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        let b = Recordings.box(from: (Double(start.x), Double(start.y)), to: (Double(p.x), Double(p.y)),
                               within: Recordings.Box(x: 0, y: 0, width: bounds.width, height: bounds.height))
        box = NSRect(x: b.x, y: b.y, width: b.width, height: b.height).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil }
        guard start != nil else { return }
        if let box, box.width >= 8, box.height >= 8 {
            picked?(box)
        } else {
            picked?(bounds)                          // a click: the whole screen
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelled?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { cancelled?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        if let box {
            NSColor.clear.setFill()
            box.fill(using: .copy)
            let border = NSBezierPath(rect: box.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            NSColor.white.setStroke()
            border.stroke()
            let size = "\(Int(box.width)) × \(Int(box.height))"
            draw(size, at: NSPoint(x: box.minX, y: box.minY - 24), small: true)
        } else {
            draw(hint, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
        }
    }

    private func attributes(small: Bool) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: small ? 12 : 17, weight: .semibold), .foregroundColor: NSColor.white]
    }

    private func draw(_ text: String, at point: NSPoint, small: Bool) {
        let s = NSAttributedString(string: text, attributes: attributes(small: small))
        let size = s.size()
        var p = point
        if p.y < 4 { p.y = 4 }
        let back = NSRect(x: p.x, y: p.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: back, xRadius: 6, yRadius: 6).fill()
        s.draw(at: NSPoint(x: p.x + 6, y: p.y + 3))
    }

    private func draw(_ text: String, centeredAt point: NSPoint) {
        let s = NSAttributedString(string: text, attributes: attributes(small: false))
        let size = s.size()
        let back = NSRect(x: point.x - size.width / 2 - 16, y: point.y - size.height / 2 - 10,
                          width: size.width + 32, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: back, xRadius: 12, yRadius: 12).fill()
        s.draw(at: NSPoint(x: back.minX + 16, y: back.minY + 10))
    }
}

// MARK: - Recording

/// Writes a box of the screen (and, with `audio`, the microphone) to an .mp4. Frames come from
/// ScreenCaptureKit, the microphone from AVCapture; both are timed on the host clock and written
/// by one AVAssetWriter. Pausing drops what comes in and, on resume, shifts what follows back by
/// the time spent paused, so the video has no gap.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let url: URL
    let withAudio: Bool
    /// The stream stopped by itself (macOS stopped it, or writing failed). On the main thread.
    var onFailed: ((String) -> Void)?

    private let queue = DispatchQueue(label: "ToolMacTool.screen-capture")
    private var stream: SCStream?
    private var mic: AVCaptureSession?
    // Everything below is used on `queue`.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private var stopping = false
    private var paused = false
    private var pausedAt = CMTime.invalid
    private var resumedAt = CMTime.zero
    /// Time spent paused so far, taken off every sample.
    private var offset = CMTime.zero
    private var lastVideo = CMTime.invalid
    private var lastAudio = CMTime.invalid
    private var failure: String?

    init(url: URL, audio: Bool) {
        self.url = url
        self.withAudio = audio
    }

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// `region` is in AppKit's screen coordinates, on `screen`.
    func start(region: CGRect, screen: NSScreen) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let display = content.displays.first(where: { $0.displayID == number?.uint32Value }) ?? content.displays.first else {
            throw Problem("No screen to record")
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let f = screen.frame
        let source = Recordings.sourceRect(Recordings.Box(x: region.minX, y: region.minY, width: region.width, height: region.height),
                                           screen: Recordings.Box(x: f.minX, y: f.minY, width: f.width, height: f.height))
        let pixels = Recordings.pixelSize(width: source.width, height: source.height, scale: screen.backingScaleFactor)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: source.x, y: source.y, width: source.width, height: source.height)
        config.width = pixels.width
        config.height = pixels.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitrate = max(2_000_000, min(24_000_000, pixels.width * pixels.height * 4))
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixels.width,
            AVVideoHeightKey: pixels.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw Problem("Couldn't set up the video") }
        writer.add(video)

        var session: AVCaptureSession?
        var audio: AVAssetWriterInput?
        if withAudio {
            guard let device = AVCaptureDevice.default(for: .audio) else { throw Problem("No microphone found") }
            let s = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard s.canAddInput(input) else { throw Problem("Couldn't use the microphone") }
            s.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            guard s.canAddOutput(output) else { throw Problem("Couldn't use the microphone") }
            s.addOutput(output)
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            a.expectsMediaDataInRealTime = true
            guard writer.canAdd(a) else { throw Problem("Couldn't set up the sound") }
            writer.add(a)
            session = s
            audio = a
        }

        queue.sync {
            self.writer = writer
            self.videoInput = video
            self.audioInput = audio
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        self.mic = session
        if let session {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    session.startRunning()
                    done.resume()
                }
            }
        }
        do {
            try await stream.startCapture()
        } catch {
            session?.stopRunning()
            throw error
        }
    }

    func pause() {
        queue.async {
            guard !self.paused else { return }
            self.paused = true
            self.pausedAt = Self.now
        }
    }

    func resume() {
        queue.async {
            guard self.paused else { return }
            let now = Self.now
            if self.pausedAt.isValid { self.offset = CMTimeAdd(self.offset, CMTimeSubtract(now, self.pausedAt)) }
            self.resumedAt = now
            self.pausedAt = .invalid
            self.paused = false
        }
    }

    /// Stops and finishes the file: `done` gets its URL, or nil and what went wrong. On the main thread.
    func stop(_ done: @escaping (URL?, String?) -> Void) {
        let stream = self.stream, mic = self.mic
        self.stream = nil
        self.mic = nil
        Task {
            try? await stream?.stopCapture()
            mic?.stopRunning()
            self.queue.async { self.finish(done) }
        }
    }

    /// On `queue`.
    private func finish(_ done: @escaping (URL?, String?) -> Void) {
        stopping = true
        let url = self.url
        guard let writer, started, writer.status == .writing else {
            let problem = failure ?? writer?.error?.localizedDescription
            if writer?.status == .writing { writer?.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { done(nil, problem ?? "Nothing was recorded") }
            return
        }
        // The video lasts until Stop (or the pause it was stopped in), even if the screen was still.
        var end = CMTimeSubtract(paused && pausedAt.isValid ? pausedAt : Self.now, offset)
        for last in [lastVideo, lastAudio] where last.isValid && CMTimeCompare(last, end) > 0 { end = last }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: end)
        writer.finishWriting {
            let ok = writer.status == .completed
            let problem = writer.error?.localizedDescription
            DispatchQueue.main.async { done(ok ? url : nil, problem) }
        }
    }

    private static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    // MARK: Samples (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer), Self.isFrame(sampleBuffer) else { return }
        append(sampleBuffer, video: true)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(sampleBuffer, video: false)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let problem = error.localizedDescription
        DispatchQueue.main.async { self.onFailed?(problem) }
    }

    /// A frame with something new in it (ScreenCaptureKit also sends "nothing changed" ones).
    private static func isFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    private func append(_ buffer: CMSampleBuffer, video: Bool) {
        guard let writer, !stopping, failure == nil, !paused else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid, CMTimeCompare(pts, resumedAt) >= 0 else { return }
        let time = CMTimeSubtract(pts, offset)
        if !started {
            guard video else { return }                 // the file starts with the first frame
            guard writer.startWriting() else {
                fail(writer.error?.localizedDescription ?? "Couldn't start writing the file")
                return
            }
            writer.startSession(atSourceTime: time)
            started = true
        }
        guard let input = video ? videoInput : audioInput, input.isReadyForMoreMediaData else { return }
        let last = video ? lastVideo : lastAudio
        if last.isValid, CMTimeCompare(time, last) <= 0 { return }
        guard let sample = CMTimeCompare(offset, .zero) == 0 ? buffer : Self.shift(buffer, back: offset) else { return }
        if input.append(sample) {
            if video { lastVideo = time } else { lastAudio = time }
        } else if writer.status == .failed {
            fail(writer.error?.localizedDescription ?? "Couldn't write the file")
        }
    }

    private func fail(_ problem: String) {
        guard failure == nil else { return }
        failure = problem
        DispatchQueue.main.async { self.onFailed?(problem) }
    }

    /// The same sample, `offset` earlier.
    private static func shift(_ buffer: CMSampleBuffer, back offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid {
                timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            }
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                                          sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                                          sampleBufferOut: &out)
        return status == noErr ? out : nil
    }
}
