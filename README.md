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
here.

The app adds itself to your login items the first time it runs. To turn that off, click the sunrise
button (**Open at login**) in the bottom bar.

The first time a tool reads Downloads or writes to the Desktop, macOS asks whether to allow it.
Click **Allow**. The app is ad-hoc signed and not notarized, so macOS may ask again after an update.

## Update

The app follows the `main` branch. It checks at launch, every 6 hours, and when you choose
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
then shows how it went. The folder button opens the target folder. **The tile** opens a window
with the same list over a longer span (10 minutes, hour, day, week). There each zip shows its
size, how many files it holds, whether everything sits inside one folder, where it would go and,
once run, which files were added and replaced.

What running it does:

1. Unzips it into a scratch folder.
2. Picks the Desktop folder it belongs to:
   - First choice: a folder with **the same name** as the zip. Case and a browser's ` (2)` suffix
     don't matter. If the zip holds a single folder, that folder's name counts too.
   - Otherwise: a folder whose **name is contained in** the zip's name. For example, Desktop
     `MyApp` matches `MyApp-main (2).zip`. If several match, the longest name wins. Names shorter
     than 3 letters only count as exact matches.
   - If nothing matches, or two folders tie, it stops without touching anything.
3. Moves the zip's contents into that folder. Subfolders are merged. A file that already exists is
   replaced, and **the old one goes to the Trash**, so you can get it back. If the zip wraps
   everything in one folder named like the zip or the target (GitHub's `MyApp-main/`), the tool
   moves what's inside that folder, not the folder itself.

The zip stays in Downloads. A card also fades in under the menu bar with a **Show in Finder**
button.

### Chat (Glass)

A floating glass shape with no window around it. It's small when empty and grows as you talk.
The edge ripples while the model thinks, it tilts toward the pointer, and it dims a little
when you're in another app. Drag it by the empty space in its top row. Its buttons open the
memory, start a new chat, shrink it to just the input box, keep it on top, and close it (⌘W).
**Return** sends; **Esc** stops a reply.

- **The model** comes from [Ollama](https://ollama.com) (`http://127.0.0.1:11434`, or the
  address in Glass's settings). Pick it from the menu at the top left. Ollama has to be running
  and have a model pulled (`ollama pull llama3.2`).
- **Memory** is Glass's own `MEMORY.md` (`~/Documents/Glass/MEMORY/MEMORY.md`, or the folder set
  in Glass's settings), so Glass and this app remember the same things. Its text goes with every
  message; only its last 6,000 characters are sent, if it grows past that. When you ask the model
  to remember something, it writes `[[remember: …]]` in its reply. That's hidden from you and
  added to the file as a dated line, and the chat shows "Remembered: …".
- **Long chats** send only their newest messages (about 16,000 characters), so they never
  overflow the model's context.
- **Every chat is saved** as `glass-chat-<time>.md` in the Glass folder, in Glass's format, so it
  shows up in Glass's transcripts too.

### Memory (Glass)

`MEMORY.md` in an editor. It shows how many words the file has and roughly how many tokens it
adds to each message. ⌘S saves. The editor reloads when the file changes on disk (the chat adds
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
`GlassBlob.swift` and `ChatView.swift` show how.

## Layout

```
Package.swift                 Swift package: ToolCore (logic), ToolMacTool (app), tests
Sources/ToolCore/             the tools' logic: zips, memory, chat context, Ollama's replies, updates (testable anywhere)
Sources/ToolMacTool/          App (menu bar), MenuView (the panel), Tools (the registry), Windows,
                              Zips, Chat + ChatView + GlassBlob, MemoryView, HUD, Updater
scripts/build-app.sh          builds ToolMacTool.app / .zip (ad-hoc signed; universal on CI, this Mac's chip locally)
.github/workflows/build.yml   test + build on every push; release on main
install.sh                    install the latest release (or build main) into ~/Applications
```

`swift test` runs the ToolCore tests on macOS or Linux.
