# Tool Mac Tool

A wrench icon in the macOS menu bar. Clicking it opens a panel of tool tiles, grouped into sections
with a divider between them. A strip under the tiles shows how the last run went. The bar at the
bottom holds updates (with the version you're on), **Open at login** and **Quit**. Hover over a
tile to see what it does. New tools get added over time, and the app updates itself from GitHub.

It's a native Mac app (Swift, SwiftUI and AppKit). You never build it by hand. GitHub Actions
builds it on every push and publishes a release when something lands on `main`. When GitHub hasn't
built a version, the app builds it on your Mac by itself.

## Install

The repository may be private, so this goes through gh (GitHub's command line tool) signed in.
Glass's installer already set that up; otherwise run `brew install gh && gh auth login` first.
Paste this in Terminal:

```bash
gh api -H "Accept: application/vnd.github.raw" repos/ainigh/tool-mac-tool/contents/install.sh | bash
```

It downloads the latest release into `~/Applications` and opens it. If there's no release yet, it
builds from the source instead. That needs Apple's command line tools, which Homebrew installs; if
they're missing, run `xcode-select --install`. `TMT_BRANCH=name` installs another branch, built
here; that copy then follows that branch when it updates.

The app adds itself to your login items the first time it runs. To turn that off, click the sunrise
button (**Open at login**) in the bottom bar.

The first time a tool reads Downloads or writes to the Desktop, macOS asks whether to allow it.
Click **Allow**. The app is ad-hoc signed and not notarized, so macOS may ask again after an update.

## Update

The app follows the `main` branch (or the branch it was installed from). It checks at launch, every 6 hours, and when you choose
the ↻ button in the bottom bar. When `main` has a commit this copy wasn't built from, the icon turns solid
and the bottom bar shows an **Update** button (hover over it for the commit's title):

- **Update to v0.1.N**: GitHub already built that commit. The app downloads it, swaps itself and
  reopens.
- **Update (build here)**: GitHub hasn't built it, either because the build is still
  running or because Actions is off. The app downloads that commit's source, builds it for this
  Mac, swaps itself and reopens. This takes a minute or two. The build output goes to
  `~/Library/Logs/ToolMacTool/update.log`.

The app talks to GitHub through gh, so it works while the repository is private, as long as gh is
signed in. The bottom bar shows the version and the commit you're on. Running the install line again works
too.

## The tools

Each tile opens that tool's window.

### Unzip to Desktop (Files)

Under the Files tiles, the panel lists every zip that landed in `~/Downloads` in the last
10 minutes. Each row shows where the zip would go. **Click a row** to run it on that zip; the row
then shows how it went. When the folder only matched part of the zip's name, the first click asks
("Click again to unzip into …") and a second click within a few seconds runs it. The folder button opens the target folder. **The tile** opens a window
with the same list over a longer span (10 minutes, hour, day, week). There each zip shows its
size, how many files it holds, whether everything sits inside one folder, where it would go and,
once run, which files were added and replaced.

What running it does:

1. Unzips it into a scratch folder. A zip with paths that point outside it (`../`) is refused.
2. Picks the Desktop folder it belongs to:
   - First choice: a folder with **the same name** as the zip. Case and a browser's ` (2)` suffix
     don't matter. If the zip holds a single folder, that folder's name counts too.
   - Otherwise: a folder whose **name appears as whole words** in the zip's name. For example,
     Desktop `MyApp` matches `MyApp-main (2).zip`, but `new` doesn't match `newsletter.zip`. If
     several match, the longest name wins. Names shorter than 3 letters only count as exact matches.
   - If nothing matches, or two folders tie, it stops without touching anything.
3. Moves the zip's contents into that folder. Subfolders are merged. A file that already exists is
   replaced, and **the old one goes to the Trash**, so you can get it back. If the zip wraps
   everything in one folder named like the zip or the target (GitHub's `MyApp-main/`), the tool
   moves what's inside that folder, not the folder itself.

If moving stops partway (a file can't be moved, say), it says what had already been added and
replaced. If Downloads or the Desktop can't be read, the list says so and links to the privacy
setting. The zip stays in Downloads. A card also fades in under the menu bar with a **Show in Finder**
button.

### Read aloud, Dictate, Transcribe (Voice)

These use macOS's own speech: the system voices to speak, and its speech recognition (on this Mac
when your language supports it) to listen. Nothing else to install. The first time one listens,
macOS asks to allow **Speech Recognition** and the **Microphone**: click **Allow**. As with the
folders, macOS may ask again after an update. If something was refused, the tool says so and
**Open Settings** goes to the right page.

- **Read aloud.** Paste or type text and press **Read** (⌘Return), or **Paste & read** what's on
  the clipboard. The word being said is lit up; **Pause** and **Stop** do what they say. The pills
  at the top pick the voice and the speed; every tool that speaks uses them. For better voices,
  download a Premium or Enhanced one in System Settings → Accessibility → Spoken Content. **Save
  audio…** writes it to a .wav file instead.
- **Dictate.** **Record** (⌘R), talk for as long as you like (pauses don't stop it), **Stop**. Then
  edit it, **Copy** it, or **Keep note** (⌘S), which adds it to that day's
  `glass-dictation-<date>.md` in the Glass folder (where Glass keeps its own dictations, so its
  transcript view lists them) and empties the box for the next one. What you're writing is kept if
  you close the window.
- **Transcribe.** Drop an audio file on the window (mp3, m4a, wav, aiff, or a video's sound), or
  **Choose file…**. Its lines come in as they're done, each with its time, and the line under the
  status fills up as it goes. **Copy** it, or save it as `.txt`, `.srt` or `.vtt` subtitles. Long
  files go to the recognizer in pieces of under a minute, each cut at the quietest moment near its
  end. It keeps going if you close the window.

### Chat (Glass)

A floating glass panel built like Glass's own page, with no window around it. Colors drift
behind the glass (livelier while you type, circling while the model thinks, washing red when
something's wrong), and a glowing line splits it in two. Above the line: a status light and the
model's name (click it to switch models), then the newest reply, as large as it fits, in the
colors moving behind the glass. Below the line: what you're typing, in the opposite colors,
smaller the more you write. When you send, your text lifts away, a ring spreads through the
glass and the old reply slides off. The panel swells a little when text changes and settles 15
seconds later.

With nothing to show it's just the status and the box; it opens up when you send. The controls
fade in while the pointer is over the panel: memory, new chat (⌘N), shrink to just the box, keep
on top, and close (⌘W). Drag it by the empty space in its top row or its bottom row. **Return**
sends, **⌥Return** starts a new line, **Esc** stops a reply (or, with nothing typed, puts the
chat away), and cut, copy, paste and undo work in the box.

Replies show Markdown: headings, bullet, numbered and task lists, quotes and rules, plus bold,
italics, `code` and links inside a line. Code blocks get their own box with a **Copy** button. A
reply too long to fit even small scrolls; while it streams it follows the end unless you've
scrolled up, and then a ↓ button takes you back down. Under the reply sit **Copy** and **Retry**
(which asks for it again), how it ended if it was stopped or failed, what was just remembered,
and ‹ › arrows to step back through earlier replies. If a reply fails before it says anything,
the warning under it offers **Try again**.

- **The model** comes from [Ollama](https://ollama.com) (`http://127.0.0.1:11434`, or the
  address in Glass's settings). Pick it from the menu at the top left. Ollama has to be running
  and have a model pulled (`ollama pull llama3.2`).
- **Memory** is Glass's own `MEMORY.md` (`~/Documents/Glass/MEMORY/MEMORY.md`, or the folder set
  in Glass's settings), so Glass and this app remember the same things. Its text goes with every
  message; only its last 6,000 characters are sent, if it grows past that. When you ask the model
  to remember something, it writes `[[remember: …]]` in its reply. That's hidden from you, and the
  chat asks **Remember "…"?** Only when you click **Remember** is it added to the file as a dated
  line, so text you paste in can't slip lasting instructions into memory. Any other `[[…]]`
  (Bash's `[[ -f x ]]`, say) and anything inside code is left as it is.
- **Long chats** send only their newest messages. The app asks Ollama for an 8,192-token context
  and fills it with the memory, as much of the conversation as fits, and room for the reply, so
  the start (with the memory) is never cut off.
- **Every chat is saved** as `glass-chat-<time>.md` in the Glass folder, in Glass's format, so it
  shows up in Glass's transcripts too.

### Chat 2, 3 and 4 (Glass)

Three more chats, the same as Chat underneath (Ollama, the model menu, the memory and its
**Remember?** questions, a saved transcript) but each built for a different way of talking. Each
keeps its own conversation and window; all four share the model setting and `MEMORY.md`. The model
is told how its replies reach you, so they suit it.

- **Chat 2: it talks back.** You type; the reply is read aloud as it streams in, a sentence at a
  time, so it starts talking with its first sentence. Code isn't read out, and neither are
  Markdown's marks. The speaker button at the top mutes it (the reply is still written). Esc stops
  the reply and the voice.
- **Chat 3: it listens.** Press the mic beside the box and talk: what you say fills the box as you
  say it and is sent when you pause. Replies are written. It doesn't listen while a reply comes in.
  You can still type. Esc (or the mic) stops listening.
- **Chat 4: talk and listen.** No box at all. It starts listening when it opens. Pause and what you
  said is sent; it answers out loud in a few plain sentences and then listens again. It doesn't
  listen while it's talking, so it never hears itself. **Click the glass or press space** to
  interrupt it (or, while you're talking, to send without waiting for the pause). Esc stops or
  starts listening; closing the window stops the microphone. Its transcript marks what you said
  as `you (voice)`.

### Memory (Glass)

`MEMORY.md` in an editor on the same glass as the chat (drag its edges to resize it). The status
light says whether there are unsaved edits; under the line are the file's path (click it to show
it in Finder), how many words it has and roughly how many tokens it adds to each message. ⌘S
saves, ⌘W closes. The editor reloads when the file changes on disk (the chat adds
to it), unless you have unsaved edits. If you save over a change made in the meantime, it asks
first.

## Adding a tool

1. Write the logic in `Sources/ToolCore/`, which uses only Foundation. Add tests in
   `Tests/ToolCoreTests/`.
2. Give it a SwiftUI view. `Zips.swift`, `ChatView.swift` and `MemoryView.swift` are examples.
3. In `Sources/ToolMacTool/Tools.swift`, add a `Tool`. It needs a short name for the tile, a
   title and description for the tooltip, an SF Symbol, and an `open` that shows its window
   (`Windows.show`). Put it in a section of `Tools.sections`, or add a new section; each section
   gets its own titled grid.
4. Push. CI tests and builds it. Merging to `main` publishes the release, and the panel offers
   the update.

For frameless, see-through UI, use `GlassPanel` (in `Windows.swift`) and draw your own shape;
`Glass.swift` (the glass panel, its moving colors and the glowing line) and `ChatView.swift` show how.

## Layout

```
Package.swift                 Swift package: ToolCore (logic), ToolMacTool (app), tests
Sources/ToolCore/             the tools' logic: zips, memory, chat context, Ollama's replies, reply Markdown,
                              spoken text and sentences, captions, dictation files, updates (testable anywhere)
Sources/ToolMacTool/          App (menu bar), MenuView (the panel), Tools (the registry), Windows,
                              Zips, Chat + ChatView + Glass, VoiceChat (chats 2–4), Voice (speak, listen,
                              transcribe) + VoiceTools (their windows), MemoryView, HUD, Updater
scripts/build-app.sh          builds ToolMacTool.app / .zip (ad-hoc signed; universal on CI, this Mac's chip locally)
.github/workflows/build.yml   test + build on every push; release on main
install.sh                    install the latest release (or build main) into ~/Applications
```

`swift test` runs the ToolCore tests on macOS or Linux.
