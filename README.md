# Tool Mac Tool

A wrench icon in the macOS menu bar with a dropdown of small tools. New tools get added over time;
the app updates itself from GitHub.

It's a native Mac app (Swift, SwiftUI and AppKit). You never build it by hand. GitHub Actions
builds it on every push and publishes a release when something lands on `main`. When GitHub hasn't
built a version, the app builds it on your Mac by itself.

## Install

Paste this in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/ainigh/tool-mac-tool/main/install.sh | bash
```

It downloads the latest release into `~/Applications` and opens it. If there's no release yet, it
builds from the source instead. That needs Apple's command line tools, which Homebrew installs; if
they're missing, run `xcode-select --install`. `TMT_BRANCH=name` installs another branch, built
here.

The app adds itself to your login items the first time it runs. You can turn that off in the menu
under **Open at login**.

The first time a tool reads Downloads or writes to the Desktop, macOS asks whether to allow it.
Click **Allow**. The app is ad-hoc signed and not notarized, so macOS may ask again after an update.

## Update

The app follows the `main` branch. It checks at launch, every 6 hours, and when you choose
**Check for updates**. When `main` has a commit this copy wasn't built from, the icon turns solid
and the menu offers the update, with the commit's title under it:

- **Update to v0.1.N**: GitHub already built that commit. The app downloads it, swaps itself and
  reopens.
- **Update (build abc1234 here)**: GitHub hasn't built it, either because the build is still
  running or because Actions is off. The app downloads that commit's source, builds it for this
  Mac, swaps itself and reopens. This takes a minute or two. The build output goes to
  `~/Library/Logs/ToolMacTool/update.log`.

The menu header shows the version and the commit you're on. Running the install line again works
too.

## The tools

### Unzip latest download to Desktop

1. Takes the **single most recent file** in `~/Downloads`. Folders and hidden files are ignored.
   If that file isn't a `.zip`, it stops and tells you. It also stops if the file is still
   downloading (`.crdownload`, `.part`, `.download`).
2. Unzips it into a scratch folder.
3. Picks the Desktop folder it belongs to:
   - First choice: a folder with **the same name** as the zip. Case and a browser's ` (2)` suffix
     don't matter. If the zip holds a single folder, that folder's name counts too.
   - Otherwise: a folder whose **name is contained in** the zip's name. For example, Desktop
     `MyApp` matches `MyApp-main (2).zip`. If several match, the longest name wins. Names shorter
     than 3 letters only count as exact matches.
   - If nothing matches, or two folders tie, it stops without touching anything.
4. Moves the zip's contents into that folder. Subfolders are merged. A file that already exists is
   replaced, and **the old one goes to the Trash**, so you can get it back. If the zip wraps
   everything in one folder named like the zip or the target (GitHub's `MyApp-main/`), the tool
   moves what's inside that folder, not the folder itself.

The zip stays in Downloads. A card fades in under the menu bar showing what happened
(`MyApp-main.zip → Desktop/MyApp (3 added, 1 replaced)`), with a **Show in Finder** button.

## Adding a tool

1. Write the logic in `Sources/ToolCore/`, which uses only Foundation. Add tests in
   `Tests/ToolCoreTests/`.
2. In `Sources/ToolMacTool/Tools.swift`, add a `Tool` (title, subtitle, SF Symbol, and a `run`
   that returns a message) and put it in `Tools.all`.
3. Push. CI tests and builds it. Merging to `main` publishes the release, and the menu offers
   the update.

Tools can have their own windows. `HUD.swift` shows how to make a borderless, transparent,
always-on-top panel: an `NSPanel` with a clear background and SwiftUI's material inside it.

## Layout

```
Package.swift                 Swift package: ToolCore (logic), ToolMacTool (app), tests
Sources/ToolCore/             the tools' logic, plus GitHub release and commit parsing (testable anywhere)
Sources/ToolMacTool/          App.swift (menu bar), MenuView, HUD, Updater, Tools (the registry)
scripts/build-app.sh          builds ToolMacTool.app / .zip (ad-hoc signed; universal on CI, this Mac's chip locally)
.github/workflows/build.yml   test + build on every push; release on main
install.sh                    install the latest release (or build main) into ~/Applications
```

`swift test` runs the ToolCore tests on macOS or Linux.
