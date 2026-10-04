# Tool Mac Tool

A wrench icon in the macOS menu bar. Clicking it opens a panel of tool tiles, grouped into sections
in two columns (so it stays short), plus a narrow third column of bigger tiles for the boards,
with dividers between them; each section has its own color,
worn by its tiles and its title. The bar at the bottom holds updates (with the
version you're on), **Open at login** and **Quit**. Hover over a tile to see what it does. New tools get added over time, and the app updates itself from GitHub.

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
builds from the source instead. That needs Apple's command line tools with Swift 6 (Xcode 16's or
newer), which Homebrew installs; if they're missing, run `xcode-select --install`. The app needs
macOS 14 (Sonoma) or newer. `TMT_BRANCH=name` installs another branch, built
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
  `~/Library/Logs/ToolMacTool/update.log`. Building needs Swift 6 (the voices' package, FluidAudio,
  requires it; an older Swift fails with "incompatible tools version"). If the command line tools
  are older but Xcode 16 or newer is installed, the build uses that Xcode. Otherwise it says so
  before downloading anything: update the command line tools
  (`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`), or wait for
  GitHub's build. When an update fails, the copy button next to the message copies the error
  with the end of the build log.

**Build tools** (the hammer in the bottom bar, **Fix…** next to a failed update, or Settings)
lists what building an update here needs and whether this Mac has it: Apple's command line tools,
Swift 6 or newer, Homebrew, gh, and gh signed in to an account that can see the repository.
**Install** (on each, or **Install what's missing** for all) puts it in: the command line tools
through Apple's installer; a newer Swift by updating the command line tools from Software Update
(or reinstalling them when it offers none), which asks for your password; Homebrew and the gh
sign-in in a Terminal window, since they need you; gh with Homebrew. **Copy report** copies every
check and its result.

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
setting. The zip stays in Downloads. A card also fades in at the middle of the screen with a
**Show in Finder** button.

### Read aloud, Dictate, Transcribe (Voice)

These speak and listen with open-source models that run on this Mac, through
[FluidAudio](https://github.com/FluidInference/FluidAudio) on Apple's Neural Engine: the
**Kokoro-82M** voices (Apache 2.0, the voices Glass used) and **Parakeet TDT v3** to write down
what's said. Each is downloaded once, the first time a tool needs it (a few hundred MB each, into
`~/.cache/fluidaudio`); the tool says "Getting … ready" meanwhile, and after that everything works
offline. They run best on Apple silicon. The first time one listens, macOS asks to allow the
**Microphone**: click **Allow**. As with the folders, macOS may ask again after an update. If it
was refused, the tool says so and **Open Settings** goes to the right page.

- **Read aloud.** Paste or type text and press **Read** (⌘Return), or **Paste & read** what's on
  the clipboard. The word being said is lit up; **Pause** and **Stop** do what they say. The pills
  at the top pick the voice and the speed; every tool that speaks uses them. There are four voices,
  Kokoro's best: **Heart** and **Bella** (women), **Michael** and **Fenrir** (men). Choosing one says
  hello in it. Each sentence is made while the one before it plays, so there are no gaps. While
  Kokoro is still downloading the first time, the Mac's own voice reads instead. **Save audio…**
  writes it to a .wav file instead.
- **Dictate.** **Record** (⌘R), talk for as long as you like (pauses don't stop it), **Stop**. The
  recording is cut into phrases at your pauses and each phrase is written down whole, in order;
  the one you're still saying shows as you say it. Nothing you say is thrown away: if speech
  recognition is still downloading, it keeps recording and writes it all down once it's there;
  after Stop it writes down the last phrase ("Writing down the last words…"); and switching
  microphones (AirPods connecting) carries on where it was. Then edit it, **Copy** it, or **Keep
  note** (⌘S), which adds it to that day's `glass-dictation-<date>.md` in the Glass folder (where
  Glass keeps its own dictations, so its transcript view lists them) and empties the box for the
  next one. What you're writing is kept if you close the window.
- **Transcribe.** Drop an audio file on the window (mp3, m4a, wav, aiff, or a video's sound), or
  **Choose file…**. Its lines come in as they're done, each with its time, and the line under the
  status fills up as it goes. **Copy** it, or save it as `.txt`, `.srt` or `.vtt` subtitles. Long
  files go to Parakeet in pieces of under a minute, each cut at the quietest moment near its end.
  It keeps going if you close the window.

### Record screen, Screen only, Record audio, Recordings (Record)

- **Record screen.** Click the tile and the screens dim: **drag a box** around what to record
  (its size shows beside it), or **click** to take the whole screen; Esc cancels. What's inside
  the box is recorded with your microphone, the box gets a red frame, and a small bar beside it
  shows the time with **Pause** (▶ to resume), **Stop** (saves) and the bin (stops and throws it
  away). The frame, the bar and the app's other windows are left out of the video. It's saved as
  `glass-recording-<time>.mp4` in the Glass folder, where Glass keeps its dictations and chats,
  and a card offers **Show in Finder**. The first time, macOS asks to allow **Screen & System Audio
  Recording** (and the **Microphone**); if it was refused, the tile opens the right settings page.
  macOS may want the app reopened after you allow it.
- **Screen only.** The same, with no sound: `glass-screen-<time>.mp4`.
- **Record audio.** Just the microphone: **Record** (⌘R), **Pause**/**Resume**, **Stop** (saves) or
  **Discard**. Saved as `glass-audio-<time>.m4a`. (Dictate writes down what you say but doesn't keep
  the sound; this keeps the sound.) Closing the window stops and saves.
- **Recordings.** A glass panel as big as the diagram's (90% of the screen) with every video and
  audio file in the Glass folder in a grid, newest first: a picture from each video, its length,
  when it was made and its size, and badges for **No sound** and **Transcript**. **All**, **Videos**
  and **Audio** filter it. Click a recording to play it, with its transcript beside it (Esc goes
  back). **Transcribe** writes down what's said in it (with Parakeet, on this Mac, as Transcribe
  does) and saves it beside the recording with the same name and `.txt` at the end
  (`glass-recording-<time>.mp4` → `glass-recording-<time>.txt`). Several can be queued; each shows
  how far it's got and can be stopped. Right-click a recording to transcribe it again, open its
  transcript, show it in Finder or move it (with its transcript) to the Trash. The buttons along
  the bottom start a new recording.

### Scheduler (Automate)

Things done for you at the times you set, while the app is open (it starts at login). The tile
opens a glass panel as big as the diagram's: your schedules down the left (each with what it
does, when, a countdown to its next run, how the last one went, and a switch), and the one you
pick on the right. **New schedule** (⌘N) adds one. Each schedule has:

- **What it does**, with its **text**:
  - **Ask the model**: the text is a prompt. The model (the chat's, or another you pick) answers
    it and, if you let it, can call the model tools and your shortcuts while it does, up to four
    rounds. It's told it's a scheduled job with nobody at the keyboard, plus the date, time and
    place. A shortcut set to ask first isn't run, since nobody is there to say yes.
  - **Remind me**: the text comes up on a card that stays until you close it.
  - **Say it**: the text is read out in the voice from Read aloud.
  - **Model tool**: the alarm (the text is the seconds), open a link, copy to the clipboard or
    draw a diagram, given the text.
  - **Shortcut**: one of your Apple Shortcuts, with the text as its input.

  The text can hold `{{date}}`, `{{time}}`, `{{last}}` (what it gave back the last time) and
  `{{clipboard}}`, filled in when it runs.
- **When**: **Once** (a date and time; it turns itself off after), **Every** so many minutes,
  hours or days (from when you set it), or **At a time of day**, every day or on the weekdays you
  pick.
- **With the result** (the model's answer, a shortcut's output): show it on a card, say it out
  loud, or both. Cards come up at the top right with **Copy**, **Say it** and **Scheduler**; a
  failure always gets a card.
- **Run now**, **Duplicate**, **Delete**, and a **history** of every run: when, whether it worked,
  the tools it used and what it gave back.

A job missed by more than an hour (the Mac was asleep, or the app closed) waits for its next time
instead of running late; one missed by less runs straight away. Schedules and the last 300 runs
are kept in `~/Library/Application Support/ToolMacTool/schedules.json`. Two examples come with it,
turned off: a reminder to stretch every hour and a spoken morning briefing on weekdays.

### Chat (Glass)

A floating glass panel built like Glass's own page, with no window around it. Colors drift
behind the glass (livelier while you type, circling while the model thinks, washing red when
something's wrong), and a glowing line splits it in two. Above the line: the newest reply, as
large as it fits, in the colors moving behind the glass. Below the line: what you're typing, in
the opposite colors, smaller the more you write. When you send, your text lifts away, a ring
spreads through the glass and the old reply slides off. The panel swells a little when text
changes and settles 15 seconds later.

The top is kept clear for the reply: **every control sits in a row along the bottom**, and they
stay hidden (only the status light shows) so nothing but the reply is on the glass. **Double-click
the glass** to show them; they go again 10 seconds after you last used them (not while the
pointer is over them), or at another double-click. The row has: the model
(click its name to switch), how you talk, the system prompt, memory on or off, the speaker (when
replies are spoken), a ⋯ menu (model, memory, prompts, settings), and on the right new chat (⌘N),
shrink to just the box, keep on top, and close (⌘W). **Drag the panel by any part of it** that
isn't the text box or a button: a press that doesn't move is still a click. **Return** sends,
**⌥Return** starts a new line, **Esc** stops a reply (or, with nothing typed, puts the chat away),
and cut, copy, paste and undo work in the box.

Replies show Markdown: headings, bullet, numbered and task lists, quotes and rules, plus bold,
italics, `code` and links inside a line. Code blocks get their own box with a **Copy** button. A
reply too long to fit even small scrolls; while it streams it follows the end unless you've
scrolled up, and then a ↓ button takes you back down. Under the reply sit **Copy** and **Retry**
(which asks for it again), how it ended if it was stopped or failed, what was just remembered,
and ‹ › arrows to step back through earlier replies. If a reply fails before it says anything,
the warning under it offers **Try again**. Every warning has a copy button, so an error can be
pasted anywhere.

- **How you talk** (the mode button, or Settings for where it starts). One chat, four ways:
  - **Type**: you type, the reply is written.
  - **Type, hear the reply**: the reply is also read aloud as it streams in, a sentence at a
    time. Code and Markdown's marks aren't read out. The speaker button mutes it.
  - **Talk, read the reply**: press the mic beside the box and talk; what you say fills the box
    and is sent when you pause. You can still type.
  - **Conversation**: no box at all. It listens, answers out loud in a few plain sentences, and
    listens again; it doesn't listen while it's talking, so it never hears itself. **Click the
    glass or press space** to interrupt it (or, while you're talking, to send without waiting for
    the pause). Esc stops or starts listening. What you said is saved as `you (voice)`.

  The same menu picks the **voice** (Heart, Bella, Michael or Fenrir), which brings its persona.
  The model is told how its replies reach you, so they suit the mode.
- **The model** comes from [Ollama](https://ollama.com) (`http://127.0.0.1:11434`, or the
  address in Settings). Ollama has to be running and have a model pulled (`ollama pull llama3.2`).
- **System prompts.** The chip in the controls shows the one in use; click it for the others, or
  press **⌘1** to **⌘9**. Up to nine, edited in **Prompts**. Six come with the app: Glass (the
  all-rounder), Brief, Tutor, Coder, Editor and Sounding board.
- **The date, time and place** go with every message, already worked out: the weekday and month
  in words, the part of the day (early morning, afternoon, late night…), the time in 12- and
  24-hour form, the time zone and its UTC offset, tomorrow's date, the week of the year, and where
  you are (from Settings, or a guess from the time zone). The model never has to reason about it.
- **Memory** is Glass's own `MEMORY.md` (`~/Documents/Glass/MEMORY/MEMORY.md`, or the folder set
  in Glass's settings), so Glass and this app remember the same things. The brain button turns
  it on or off for the chat. While it's on, the **memory prompt** (edited in Prompts) goes with
  every message, with the memory in it (its last 6,000 characters), and tells the model to use
  what's there and keep it up to date: it writes `[[remember: …]]` for a lasting fact and
  `[[forget: …]]` for one that's wrong or that you asked it to forget. Those tags are hidden;
  the change is made and shown under the reply ("Remembered: …") with **Undo**. If you'd rather
  approve each one, Settings has **Ask me first**, and then the chat asks **Remember "…"?** or
  **Forget "…"?**. Any other `[[…]]` (Bash's `[[ -f x ]]`, say) and anything inside code is left
  as it is.
- **This Mac.** With the date and time, the model is told what this Mac is (model, chip, memory,
  cores, macOS) and how long it has been on since it started up. Settings can turn that off.
- **Say "close" or "exit"** (or "bye", "go away", "close the window") while it listens and the
  window closes at once, without asking the model. Longer ways of saying it go to the model, which
  can close it with its `close_window` tool.
- **Long chats** send only their newest messages. The app asks Ollama for the context window set
  in Settings (8K tokens to start) and fills it with the system message, as much of the
  conversation as fits, and room for the reply, so the start (with the memory) is never cut off.
- **Every chat is saved** as `glass-chat-<time>.md` in the Glass folder, in Glass's format, so it
  shows up in Glass's transcripts too.

### Model tools

Tools built into the app that the chat's model can call (when tools are on, and it's a model that
can call tools). Each is **one way**: the model is only told it was done and carries on. The
**Model tools** window (the Alarm, Open link and Clipboard tiles, or the chat's ⋯ menu) turns each
on or off, holds its description (when the model should call it, like a prompt; **Restore
default** brings the original back) and has **Try it**.

- **Diagram** (`draw_diagram`): the model describes what to draw; the Diagram tool's own model
  draws it in its window, which comes up on screen. The chat never sees the diagram.
- **Alarm** (`sound_alarm`): a loud two-tone beep for the number of seconds the model asks (1 to
  600), with a small card at the top of the screen to **Stop** it (or Esc).
- **Open link** (`open_url`): opens a web page (http or https only) in your default browser; the
  chat stays where it is.
- **Clipboard** (`copy_to_clipboard`): puts text on the clipboard.
- **Close the chat** (`close_window`): closes the chat when you say you're done.

### Shortcuts (Model tools)

Lets the chat's model run your **Apple Shortcuts**. Add shortcuts from the list of the ones you
have, and for each write **when to call it** (like a prompt: what it does, when the model should
use it and when not) and **what to pass it**. Each shortcut takes one piece of text and either
**gives text back**, which the model reads and uses in its reply, or is **one way**, and the model
is only told it ran. **Ask me before each run** shows what it's about to be given and waits for
you. **Try it** runs a shortcut with some text right there and shows what came back.

In the chat, the status says "Running Weather…" while one runs, and the reply says which ones
ran. A reply can call shortcuts up to four rounds before it has to answer, and later replies
still see what they returned. The chat's ⋯ menu turns tools off for that chat; the switch at the
top of Tools turns them off everywhere. Shortcuts are run with macOS's `shortcuts` command, so the
first run may ask for permission. Not every model can call tools (llama3.1 and newer, qwen2.5 and
newer, mistral and others can): with one that can't, the chat answers without them.

### Diagram (Glass)

A glass canvas covering most of the screen (90% of it). It opens from its tile, or when the chat's
model draws something (see Model tools). Type, or press the mic and say, what you
want drawn: the model answers with a [Mermaid](https://mermaid.js.org) diagram (the language
models already know well) and the app draws it its own way, as a network in the style of Mind Map
Studio's network view: every node a large icon in its color, picked from its label (about 270
brands and cloud services by name, Stripe, Cloudflare, PostgreSQL, Kafka, "AWS Lambda", and plain
words through Lucide's icons, "customer" → people, "payment" → a banknote; an emoji in a label is
its icon), with the label and a short description (what follows a `<br>`) under it; connections as
elbows with rounded corners, shaded from one node's color to the other's, with a comet running along
each to show which way it goes and its label on a pill; subgraphs as tinted frames with their title.
It lays itself out: layered so connections run straight where they can, boxes laid out inside first,
links into one node side by side so their labels stay clear, and of top-down, left-right and (for a
hub with four or more branches) a two-sided mind map, whichever shows largest in the window. A hub
gets a larger icon on a pulsing tile, its branches a color each; with no hub the colors run round
the wheel along the flow. Flowcharts (`graph` too), mind maps, state, class (members under the name),
ER (attributes), sequence (participants and their messages), timeline and architecture diagrams are
drawn this way, and the model is asked to use a flowchart unless something else fits better; pie
charts, gantt charts and the other kinds that aren't graphs are drawn by Mermaid itself. Ask for a
change ("add a cache between the app and the database") and it redraws from the
diagram as it stands: each request sends the current diagram and only the previous exchange, no
memory and no chat history. If what it wrote won't draw, Mermaid's error goes back to it once to
fix (Mermaid's, or the line that wouldn't read). **Undo** goes back to the diagram before (and again to come forward), **Mermaid** opens the
code beside the canvas to read or edit (and **Draw this**), and you can copy the Mermaid or the
SVG. Pinch to zoom. The canvas (`Sources/ToolMacTool/Network`: its page, `network.js`, and Mind Map
Studio's Mermaid reader and icons, which `scripts/sync-network.sh` copies from that repository) ships
in the app and is put in `~/Library/Application Support/ToolMacTool/mermaid` with Mermaid's script,
which is downloaded once, the first time (from cdn.jsdelivr.net); without it, everything but the
kinds Mermaid draws still draws. The model is the chat's unless Settings
picks another for diagrams. As in the chat, the controls along the bottom are hidden until you
double-click the glass, any part of the glass drags it, and saying "close" while it listens
closes it.

### Prompts (Glass)

Three tabs:

- **System prompts**: up to nine, in the order the chat lists them (⌘1 to ⌘9). Add, duplicate,
  delete, drag to reorder, and pick the one new chats start with (★). **Restore the default
  prompts** brings back the six that came with the app.
- **Memory prompt**: the one prompt that tells the model how to use `MEMORY.md` and keep it up to
  date. `{{memory}}` is where the memory goes.
- **Personas**: who the model is when it speaks in each voice (Heart is warm and calm, Bella
  bright and curious, Michael steady and practical, Fenrir dry and direct). Used when replies are
  spoken, or always, or never, as Settings says.

### Settings (Glass)

So the other tools have nothing to set up: Ollama's address, the chat model and (optionally) a
different one for diagrams, the context window, temperature and whether reasoning models think
first; how the chat starts (mode, system prompt, memory on, save memories or ask first, when
personas apply); the voice and its speed; and the time zone, your location and 12- or 24-hour
time, with a preview of exactly what the model is told. Changes are saved as you make them, in
`~/Library/Application Support/ToolMacTool/settings.json`. The first time, the address and model
come from Glass's settings.

### Memory (Glass)

`MEMORY.md` in an editor on the same glass as the chat (drag its edges to resize it). The status
light says whether there are unsaved edits; under the line are the file's path (click it to show
it in Finder), how many words it has and roughly how many tokens it adds to each message. ⌘S
saves, ⌘W closes. The editor reloads when the file changes on disk (the chat adds
to it), unless you have unsaved edits. If you save over a change made in the meantime, it asks
first.

### Timers

Six timer tiles and a battery, each set by **clicking it to step through its choices** (past the
last one it's off); right-click one to pick a choice straight away, restart, snooze or stop it, and
the small ✕ on a running tile stops it. A ring round the icon shows what's left, and the line under
the name the time. Each timer has its own sound, and its card covers **a quarter of the screen**
(half as wide, half as tall) in its own spot, the words zoomed to fill it.

- **Timer 1** (1, 3, 5, 10, 15 min; top left) and **Timer 2** (20, 30, 45 min, 1 h, 1 h 30, 2 h;
  bottom left) count down once. At zero they ring, loud (three quick beeps; a siren), until you
  click **OK** (the sound stops by itself after two minutes, the card stays). **Snooze 3 min**
  quiets it and rings again three minutes later, once per countdown. **Again** starts it over.
- **Repeat 1** (15, 20, 25, 30 min; top right) and **Repeat 2** (45, 50, 60, 90 min; bottom
  right) count down, ring softly (two falling notes; three rising ones), stay at 0:00 for five
  minutes, then start again, round after round, until you stop them. One snooze a round.
- **Reminders** (the four above): on the way down, a card the same size comes up in the middle of
  the screen and fades away within about three seconds, saying how long is left. They come at half
  of what's left each time, in whole minutes, down to a minute: for an hour, at 30, 15, 7, 3 and
  1 minute left. Clicks pass through them.
- **Day chime** (on or off; top middle): every hour from 6 AM to 10 PM, a bright ding and a card
  with the time ("Monday 2 PM"), how many hours have passed since 6 AM and how many are left to
  10 PM, with a bar for the day so far.
- **Night watch** (on or off; bottom middle): every hour from 11 PM to 5 AM, a low ding-dong and a
  red, pulsing warning card with the time ("Tuesday 1 AM") and how many hours are left before 6 AM.
- **Battery**: click to set it to 100, 80, 60, 40, 20 or 0% (one step a click). It drains 20% an
  hour, like a countdown, and stops at 0. Nothing pops up: it shows on its tile, in the Timer log's
  battery chart, and in the signals.

The chimes keep the time zone set in Settings. Timers keep going while the app is closed and pick
up when it opens again: a countdown that ended over an hour ago switches off quietly, and a chime
or reminder that's long past is skipped.

### Timer log (Timers)

A big glass report of everything the timers did, kept in
`~/Library/Application Support/ToolMacTool/timer-log.json`. Pick today, 7 days or 30 days:

- **Totals**: alarms, snoozes (and per day), times set, the days anything was set, chimes,
  batteries emptied, thresholds crossed.
- **A timeline**: when each alarm went off, each snooze, each time a timer was set or stopped, one
  row per timer.
- **Alarms and snoozes per day** (hover a day for its numbers), and a dot per day: filled when a
  timer or the battery was set, hollow when nothing was.
- **The battery's level** over time, with where it ran out.
- **Every entry**, newest first.

Its **Thresholds & signals** side sets:

- **Thresholds**: "Snoozes in a day over 4" (the default), or alarms, times set, stops or
  batteries emptied over any number. The moment a day's count goes over, a card comes up in the
  middle of the screen until you click **OK**. Add as many as you like, or turn them off.
- **Signals**: an address (a Cloudflare worker, say) that each signal is POSTed to as JSON, with an
  optional secret sent as `Authorization: Bearer …`. Pick what goes: thresholds crossed, the
  battery (set, every 10% on the way down, empty) and every alarm and snooze. Signals that don't get
  through are kept (up to 500) and retried every minute; a 4xx answer drops one. **Send a test**
  tries the address, and the pane shows what a signal looks like:

  ```json
  {"app":"ToolMacTool","at":"2026-10-04T15:02:11Z","day":"2026-10-04","detail":"Snoozes in a day over 4: 5 snoozes today",
   "device":"Sam's MacBook","id":"…","kind":"threshold","name":"Thresholds","source":"thresholds",
   "threshold":{"count":5,"limit":4,"metric":"snoozes","rule":"Snoozes in a day over 4"},"type":"threshold","value":5}
  ```

  `type` is `threshold`, `battery`, `alarm`, `snooze` or `test`; `id` repeats when a send is
  retried, so a worker can drop one it has already seen.

### Goals, Strategies, Entities, Notes (Boards)

Four boards, each a big window of boxes to type into. They have the panel's third column to
themselves, their tiles a size bigger and stacked. The arrows at the top show more or fewer boxes
(1 to 36); a hidden box keeps its text for when it's shown again. The boxes fill the window, the
gutter between them narrowing as there are more. Double-click a box to step it through light
colors. In each box's top right corner, the copy icon copies its text and the open icon opens it
to fill the window (click again to go back to the grid). Everything is saved as you go, in
`~/Library/Application Support/ToolMacTool/boards/<board>.json`.

## Adding a tool

1. Write the logic in `Sources/ToolCore/`, which uses only Foundation. Add tests in
   `Tests/ToolCoreTests/`.
2. Give it a SwiftUI view. `Zips.swift`, `ChatView.swift`, `DiagramView.swift` and `MemoryView.swift`
   are examples. Settings it needs go in `AppSettings` (ToolCore), shown in `SettingsView.swift`.
3. In `Sources/ToolMacTool/Tools.swift`, add a `Tool`. It needs a short name for the tile, a
   title and description for the tooltip, an SF Symbol, and an `open` that shows its window
   (`Windows.show`). Put it in a section of `Tools.sections`, or add a new section (with its own
   color); each section gets its own titled grid.
4. Push. CI tests and builds it. Merging to `main` publishes the release, and the panel offers
   the update.

For frameless, see-through UI, use `GlassPanel` (in `Windows.swift`) and draw your own shape;
`Glass.swift` (the glass panel, its moving colors and the glowing line) and `ChatView.swift` show how.

## Layout

```
Package.swift                 Swift package: ToolCore (logic), ToolMacTool (app), tests
Sources/ToolCore/             the tools' logic: zips, memory, chat context, Ollama's replies, reply Markdown,
                              settings, prompts and personas, the date and time for the model, diagrams,
                              shortcuts as tools and tool calls,
                              spoken text and sentences, captions, phrases, voices, dictation files,
                              recordings (names, transcripts, the box on screen), schedules (when jobs run,
                              their text, history), timers (what's due when, reminders, snoozes, their sounds), the timer log (counts, thresholds, signals, the battery), boards (boxes, their colors, the grid), updates
                              (testable anywhere)
Sources/ToolMacTool/          App (menu bar), MenuView (the panel), Tools (the registry), Windows,
                              Zips, Chat + ChatView + Glass, VoiceChat (the chat's voice modes), DiagramView,
                              ShortcutTools (running shortcuts, the Tools window), ModelTools (the built-in
                              tools, the alarm, this Mac), BuildTools,
                              Preferences + SettingsView (settings, prompts, personas), Neural (the speech
                              models), Voice (speak, listen, transcribe) + VoiceTools (their windows),
                              ScreenRecorder (the box, the bar, recording the screen), RecordingsView
                              (Record audio, the Recordings gallery), Scheduler + SchedulerView (jobs at set
                              times, the result card, the Scheduler's window),
                              Timers (the timer tiles, their sounds and cards), BigCards (the quarter-screen cards),
                              ActivityStore (the log, thresholds, sending signals), TimerLogView (the report),
                              BoardView (the boards: Goals, Strategies, Entities, Notes),
                              MemoryView, HUD, Updater
Sources/ToolMacTool/Network/  the diagram canvas: canvas.html, network.js (the network view), and from Mind Map
                              Studio mermaid.js (reads Mermaid) and the icons (icons, icon-set, icon-brands,
                              icon-match); shipped as the app's resources
scripts/sync-network.sh       copies Mind Map Studio's Mermaid reader and icons into Network/
scripts/build-app.sh          builds ToolMacTool.app / .zip (ad-hoc signed; universal on CI, this Mac's chip locally)
.github/workflows/build.yml   test + build on every push; release on main
install.sh                    install the latest release (or build main) into ~/Applications
```

`swift test` runs the ToolCore tests on macOS or Linux.
