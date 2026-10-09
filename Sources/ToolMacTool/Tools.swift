import AppKit
import SwiftUI

/// One tile in the panel. Clicking it opens the tool's window. To add a tool: write its logic in
/// ToolCore (so it can be tested), give it a view, then add a `Tool` below and put it in a section
/// of `Tools.sections`.
struct Tool: Identifiable {
    let id: String
    /// The tile's label: a word or two.
    let name: String
    /// The full name, shown when you hover.
    let title: String
    /// What it does, shown when you hover.
    let subtitle: String
    /// An SF Symbol name (see the SF Symbols app).
    let symbol: String
    /// What clicking the tile does (usually: open its window).
    let open: @MainActor (AppModel) -> Void
}

struct ToolSection: Identifiable {
    /// Something shown with (or instead of) the tiles: the zips downloaded lately, the chimes'
    /// switches (after the tiles), the notes running a timer, the schedules that are on, the tags' boards.
    enum Extra { case recentZips, chimes, timedNotes, scheduledJobs, tagBoards }
    /// How its tiles are laid out: four across, or bigger ones stacked in a column of their own.
    enum Style { case grid, stack }

    let title: String
    /// The section's color: its tiles and its title wear it, so a tile's group shows at a glance.
    let color: Color
    let tools: [Tool]
    /// Something shown under the tiles, for quick use without opening a window.
    var extra: Extra? = nil
    var style = Style.grid
    var id: String { title }
}

enum Tools {
    static let timersColor = Color(red: 0.90, green: 0.30, blue: 0.62)
    static let scheduledColor = Color(red: 0.20, green: 0.70, blue: 0.36)
    static let batteryColor = Color(red: 0.20, green: 0.66, blue: 0.42)
    static let boardsColor = Color(red: 0.36, green: 0.40, blue: 0.92)
    static let tagsColor = Color(red: 0.85, green: 0.45, blue: 0.10)
    static let dockColor = Color(red: 0.45, green: 0.45, blue: 0.52)

    /// The row across the very top of the panel: every board, each in its own color (BoardsRow).
    static var boards: [Tool] { BoardStore.kinds.map(board) }

    /// Under the boards, in a row of its own with the battery.
    static let files = ToolSection(title: "Files", color: Color(red: 0.16, green: 0.48, blue: 0.96), tools: [unzip],
                                   extra: .recentZips)

    /// The panel's columns under the top rows, each top to bottom: a titled grid of tiles per
    /// section. The last three are narrow: the notes running a timer (docked there by themselves
    /// while it runs), the schedules that are on, and the tags' boards, each gathering the notes
    /// with that tag.
    static let columns: [[ToolSection]] = [
        [
            // Things done for you at the times you set, or when something happens; what they do;
            // the log that charts the timers; and the chimes (built-in schedules: a click turns one
            // on or off).
            ToolSection(title: "Automate", color: Color(red: 0.20, green: 0.70, blue: 0.36), tools: [scheduler, actions, timerLog],
                        extra: .chimes),
            ToolSection(title: "Voice", color: Color(red: 0.62, green: 0.33, blue: 0.95), tools: [readAloud, dictate, talkToType, transcribe]),
            ToolSection(title: "Record", color: Color(red: 0.93, green: 0.27, blue: 0.33),
                        tools: [recordScreen, recordScreenOnly, recordAudio, recordings, screenshot]),
        ],
        [
            ToolSection(title: "Glass", color: Color(red: 0.05, green: 0.66, blue: 0.70), tools: [chat, memory, prompts, settings, components]),
            // What the chat's model can do for you (it calls them as tools); each also works by itself.
            ToolSection(title: "Model tools", color: Color(red: 0.96, green: 0.56, blue: 0.10),
                        tools: [diagram, alarm, openLink, clipboard, shortcutTools]),
            // Names out of text before it goes anywhere: a map of words to stand-ins, kept here.
            ToolSection(title: "Privacy", color: Color(red: 0.36, green: 0.42, blue: 0.55), tools: [redact, redactionMap]),
        ],
        [
            // The notes running a timer or a due date, soonest first: a click opens one.
            ToolSection(title: "Timers", color: timersColor, tools: [], extra: .timedNotes, style: .stack),
        ],
        [
            // The schedules that are on, the next to run first: a click opens one in the Scheduler.
            ToolSection(title: "Scheduled", color: scheduledColor, tools: [], extra: .scheduledJobs, style: .stack),
        ],
        [
            // A board per tag, each gathering every note with that tag.
            ToolSection(title: "Tags", color: tagsColor, tools: [], extra: .tagBoards, style: .stack),
        ],
    ]

    /// Every section: the top row's, then the columns', left first.
    static var sections: [ToolSection] { [files] + columns.flatMap { $0 } }

    static var all: [Tool] { boards + sections.flatMap(\.tools) }

    static let unzip = Tool(
        id: "unzip-to-desktop",
        name: "Unzip to Desktop",
        title: "Unzip downloads to Desktop",
        subtitle: "Zips downloaded in the last 10 minutes are listed under the tiles: click one to move what's in it into its matching Desktop folder. The tile opens the full list.",
        symbol: "doc.zipper",
        open: { model in
            Windows.show("zips", title: "Recent zips", size: NSSize(width: 620, height: 460)) {
                ZipWindow(zips: model.zips)
            }
        })

    static let chat = Tool(
        id: "chat",
        name: "Chat",
        title: "Chat with Glass",
        subtitle: "A floating glass panel to chat with a local model (through Ollama). Type, talk, or both: pick how from its controls. It remembers what matters in MEMORY.md, uses the system prompt you pick (⌘1–⌘9), and knows the date, time and place.",
        symbol: "bubble.left.and.text.bubble.right",
        open: { model in ChatWindow.show(model.chat, link: model.chatLink) })

    static let diagram = Tool(
        id: "diagram",
        name: "Diagram",
        title: "Draw a diagram (Mermaid)",
        subtitle: "Say or type what you want drawn: the model writes it in Mermaid and the app draws it as a network on a big glass canvas, every node an icon picked from its name. Ask for changes and it redraws from the current diagram. The chat's model can open it too (draw_diagram), describing what to draw.",
        symbol: "point.3.connected.trianglepath.dotted",
        open: { model in DiagramWindow.show(model.diagram) })

    static let components = Tool(
        id: "components",
        name: "Components",
        title: "Note components: blocks a note can hold",
        subtitle: "Checklists, tables, kanban boards, contacts, progress bars, countdowns, habit trackers, a calculator, callouts, code, bookmarks, pictures, and buttons that run your actions and shortcuts. Type / in any note to put one in; here, see each, try it, and add it to a note.",
        symbol: "square.stack.3d.up",
        open: { model in ComponentsWindow.show(boards: model.boards) })

    static let prompts = Tool(
        id: "prompts",
        name: "Prompts",
        title: "System prompts, memory prompt and personas",
        subtitle: "Up to nine system prompts to pick from in the chat, the prompt that tells the model how to use and keep its memory, and a persona for each voice.",
        symbol: "text.quote",
        open: { _ in PromptsWindow.show() })

    static let alarm = Tool(
        id: "alarm",
        name: "Alarm",
        title: "Alarm (a model tool)",
        subtitle: "The chat's model can sound an alarm for a number of seconds (sound_alarm). Here: turn it on or off, say when it should, and try it.",
        symbol: "alarm",
        open: { _ in ModelToolsWindow.show(.soundAlarm) })

    static let openLink = Tool(
        id: "open-link",
        name: "Open link",
        title: "Open a link (a model tool)",
        subtitle: "The chat's model can open a web page in your browser (open_url), and carry on talking.",
        symbol: "safari",
        open: { _ in ModelToolsWindow.show(.openURL) })

    static let clipboard = Tool(
        id: "clipboard",
        name: "Clipboard",
        title: "Copy to the clipboard (a model tool)",
        subtitle: "The chat's model can put text on your clipboard (copy_to_clipboard), ready to paste.",
        symbol: "doc.on.clipboard",
        open: { _ in ModelToolsWindow.show(.copyText) })

    static let shortcutTools = Tool(
        id: "tools",
        name: "Shortcuts",
        title: "Tools: shortcuts the model can run",
        subtitle: "Pick Apple Shortcuts the chat's model may call, and say when it should call each. Each takes text and gives text back (or nothing).",
        symbol: "bolt.horizontal.circle",
        open: { _ in ToolsWindow.show() })

    static let settings = Tool(
        id: "settings",
        name: "Settings",
        title: "Settings",
        subtitle: "The model and where Ollama is, how the chat starts (mode, prompt, memory), the voice, and the time zone and place the model is told about.",
        symbol: "gearshape",
        open: { _ in SettingsWindow.show() })

    static let readAloud = Tool(
        id: "read-aloud",
        name: "Read aloud",
        title: "Read aloud (text to speech)",
        subtitle: "Paste or type text and it's read out, the word being said lit up. Pick the voice and speed, or save it as audio.",
        symbol: "text.bubble",
        open: { model in ReadAloudWindow.show(model.speaker) })

    static let dictate = Tool(
        id: "dictate",
        name: "Dictate",
        title: "Dictate notes (speech to text)",
        subtitle: "Talk and it's written down, as long as you like. Edit, copy, or keep it with Glass's dictations (glass-dictation-<date>.md).",
        symbol: "mic",
        open: { model in DictateWindow.show(model.listener) })

    static let talkToType = Tool(
        id: "talk-to-type",
        name: "Talk to type",
        title: "Talk to type: dictate into any text field",
        subtitle: "Hold right ⌥ (or the key you pick) anywhere, talk, and let go: what you said is typed where the cursor is, in a browser or any app. Tap it to keep listening hands-free; Esc drops it. Written down on this Mac. Needs Accessibility.",
        symbol: "waveform.and.mic",
        open: { _ in TalkToTypeWindow.show() })

    static let transcribe = Tool(
        id: "transcribe",
        name: "Transcribe",
        title: "Transcribe an audio file",
        subtitle: "Drop an audio file (mp3, m4a, wav…) to get its transcript, timed. Copy it, or save it as text or subtitles (.srt, .vtt).",
        symbol: "waveform",
        open: { model in TranscribeWindow.show(model.transcriber) })

    static let recordScreen = Tool(
        id: "record-screen",
        name: "Record screen",
        title: "Record a box of the screen, with sound",
        subtitle: "Drag a box on the screen (or click for the whole screen) and what's in it is recorded with your microphone. Pause, resume and stop from the bar beside it. Saved as glass-recording-<time>.mp4 in the Glass folder.",
        symbol: "rectangle.dashed.badge.record",
        open: { model in model.screenRecorder.begin(audio: true) })

    static let recordScreenOnly = Tool(
        id: "record-screen-only",
        name: "Screen only",
        title: "Record a box of the screen, no sound",
        subtitle: "Like Record screen, without the microphone: drag a box, then pause, resume and stop from the bar beside it. Saved as glass-screen-<time>.mp4 in the Glass folder.",
        symbol: "rectangle.dashed",
        open: { model in model.screenRecorder.begin(audio: false) })

    static let recordAudio = Tool(
        id: "record-audio",
        name: "Record audio",
        title: "Record audio (the microphone)",
        subtitle: "Record, pause, resume and stop: your microphone, saved as glass-audio-<time>.m4a in the Glass folder. Dictate writes down what you say; this keeps the sound.",
        symbol: "record.circle",
        open: { model in AudioRecorderWindow.show(model.audioRecorder) { RecordingsWindow.show(model) } })

    static let screenshot = Tool(
        id: "screenshot",
        name: "Screenshot",
        title: "Screenshot to the clipboard",
        subtitle: "Drag a box on the screen (or click for the whole screen) and a picture of it goes on the clipboard, ready to paste anywhere (⌘V). Esc cancels.",
        symbol: "camera.viewfinder",
        open: { model in model.screenshots.take() })

    static let recordings = Tool(
        id: "recordings",
        name: "Recordings",
        title: "Recordings: play and transcribe",
        subtitle: "Every screen and audio recording in the Glass folder, in a grid on a big glass panel. Play one beside its transcript, or transcribe it: the text is saved beside it with the same name and .txt at the end.",
        symbol: "play.rectangle.on.rectangle",
        open: { model in RecordingsWindow.show(model) })

    static let scheduler = Tool(
        id: "scheduler",
        name: "Scheduler",
        title: "Scheduler: things done at the times you set",
        subtitle: "Once, every so often, at a time of day, every hour, or when something happens (an alarm, the battery, a day's count over a limit, the month starting): run one of your actions, with the values its arguments need. The day chime and the night watch are built in. Runs while the app is open.",
        symbol: "calendar.badge.clock",
        open: { model in SchedulerWindow.show(model.scheduler) })

    static let actions = Tool(
        id: "actions",
        name: "Actions",
        title: "Actions: what schedules do",
        subtitle: "Steps done in turn: ask the model (it can use the model tools and your shortcuts), show a reminder, say something, run a model tool or a shortcut, call a web address, chime, or run other actions. Give an action arguments to use as {{name}} in its steps ({{last}} is what the step before gave back); schedules, and steps of other actions, give their values. Run one by hand here.",
        symbol: "square.stack.3d.down.right",
        open: { model in ActionsWindow.show(model.scheduler) })

    static let timerLog = Tool(
        id: "timer-log",
        name: "Timer log",
        title: "Timer log: when alarms went off, snoozes, the battery",
        subtitle: "A big report of the timers: when each was set, went off or was snoozed, counts per day (and the days nothing was set), the battery's level over time, and the thresholds and signals (scheduler jobs that wait for a count to go over a limit, or call your web address).",
        symbol: "chart.bar.xaxis",
        open: { model in TimerLogWindow.show(model) })

    static let redact = Tool(
        id: "redact",
        name: "Redact",
        title: "Redact names from text",
        subtitle: "Paste text: the model on this Mac finds every person's name (new ones join the Redaction map), then each word in the map is swapped for its stand-in, the same way every time. Restore swaps them back. Optionally with the substitutions at the top.",
        symbol: "eye.slash",
        open: { _ in RedactWindow.show() })

    static let redactionMap = Tool(
        id: "redaction-map",
        name: "Redaction map",
        title: "The redaction map: words and their stand-ins",
        subtitle: "Every name you've redacted (or learned from past text), each with what stands in for it. Change the stand-ins, give one person's several names the same one, keep words that aren't names. Kept on this Mac.",
        symbol: "list.bullet.rectangle",
        open: { _ in RedactionMapWindow.show() })

    static let memory = Tool(
        id: "memory",
        name: "Memory",
        title: "Glass's memory",
        subtitle: "View and edit MEMORY.md: what Glass knows about you, sent with every message while memory is on, and kept up to date by the model.",
        symbol: "brain",
        open: { _ in MemoryWindow.show() })

    static func board(_ kind: BoardStore.Kind) -> Tool {
        Tool(id: "board-\(kind.id)",
             name: kind.name,
             title: "\(kind.name): a board of notes",
             subtitle: "A big glass panel of notes to type into, the first line of each its title. The arrows either side show more or fewer (hidden ones keep their text). Double-click a note to change its color. Drag a note anywhere on it to put it in another's place, and by its bottom right corner to make it span more blocks. Down its left: its icon (click to pick another), and from the bottom up 2, 5, 10, 15, 30 and 45-minute timers (any at once): at zero the note opens to fill its board and the day chime rings every 3 seconds until you change its status, then it starts over. Top left: Daily (or only AMs, PMs or Nightly), Weekly or Monthly, for a reminder every hour from 8 AM until it's done (each day, week or month begins at 8 AM the day before), then a due date (the note shows in the panel's Timers column while it runs). Top right: its tags (Important, Urgent, Delegate, Think), the top of the note in their colors. Above its bottom, in the middle: To do, Pending, 10% to 90%, Completed. Down its top right: copy, open it to fill the board, dock it along the bottom of this panel, and pin it to float on your screen. Paste a web address to see its page's icon and title (a YouTube video plays in the note). Right-click the tile to dock the board in the menu bar.",
             symbol: kind.symbol,
             open: { model in model.boards.show(kind.id) })
    }
}
