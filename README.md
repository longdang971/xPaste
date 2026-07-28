# xPaste

A fast, native clipboard manager for macOS. xPaste lives in your menu bar,
keeps a searchable history of everything you copy, and pastes it back into any
app with a single shortcut.

Built with SwiftUI + AppKit. Version 1.1.1 · Powered by LQ Team.

## Features

- **Rich clipboard history** — automatically captures and classifies what you copy:
  - **Text** and **Links** (URLs get a live preview with title, image, and favicon)
  - **Images** (screenshots, copied bitmaps — stored and previewed)
  - **Files** and **Folders** (distinguished automatically; app bundles like `.app`
    are treated as files)
  - **Colors** — hex / `rgb()` / `hsl()` strings are detected and shown as a swatch
- **Paste files & folders as a path** — pasting a file/folder item drops the actual
  file in Finder *and* the plain-text path into text fields, so you always get the
  path where you need it.
- **Formatting preserved** — rich text (RTF/HTML) is kept so styled content pastes
  with its styling; a plain-text fallback is always included.
- **Global shortcut** — press **⇧⌘V** (configurable) to open the panel and paste.
- **Pin, search, and preview** — pin frequently used items, search the history, and
  press Space to open a full preview (web preview for links, image/file details).
- **Drag items out** — drag a card straight into Finder, Mail, or any editor. Files and
  images drop as the real file; links drop as a clickable URL.
- **Name your items** — double-click a card's title (or right-click › Name…) to edit it in place
  (⏎ saves, ⎋ cancels).
  The card shows the name instead of its type and the name is searchable, which turns the Pin tab
  into a snippet library.
- **Paste as…** — right-click an item to paste it trimmed, on a single line, upper/lowercase,
  capitalized, as pretty or minified JSON, URL-encoded/decoded, or as just the link's domain.
- **Paste a whole selection** — ⌘-click several cards and press **↩** to paste them at once,
  joined by a separator you choose in Settings.
- **Filters** — the filter button at the right of the search field opens a popover to narrow the
  history by **Type** (Text, Link, Image, Color, File, Folder), by **App** (only the apps actually
  in your history), and by **Date** (Today, Yesterday, This week, Last week, Last 30 days). Each
  active filter appears as a token inside the search field — click a token to drop it. Choices
  inside a section are OR-ed, sections are AND-ed. The same thing can be typed into the search
  box: `img:`, `link:`, `text:`, `file:`, `folder:` (or `type:image`) and `app:chrome`, combined
  with free text.
- **Text inside screenshots** — images are read with Vision on capture, so searching for a word
  written inside a screenshot finds it.
- **Hover actions** — pin and delete buttons appear on a card as the pointer reaches it.
- **Privacy-aware** — skips confidential content (password-manager pasteboard hints),
  transient content, any apps you add to the ignore list, and any text matching your own
  never-save patterns (plain words or `/regular expressions/`). Passwords.app and Keychain
  Access are ignored out of the box.

## Requirements

- macOS 13.0 (Ventura) or later
- **Accessibility permission** — required so xPaste can paste into other apps
  (System Settings → Privacy & Security → Accessibility)

## Install (prebuilt)

Build a Release version and drop it into `/Applications`:

```bash
xcodegen generate          # regenerate the Xcode project from project.yml
xcodebuild -scheme xPaste -configuration Release \
  -derivedDataPath build clean build
cp -R build/Build/Products/Release/xPaste.app /Applications/
open /Applications/xPaste.app
```

> After replacing the app bundle, macOS may reset the Accessibility permission —
> re-grant it in System Settings if pasting stops working.

## Develop

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open xPaste.xcodeproj
```

Run the tests:

```bash
xcodebuild test -scheme xPaste -destination 'platform=macOS'
```

## Settings

Accessible from the menu bar icon:

- **General** — launch at login, show/hide the menu bar icon
- **Shortcut** — customize the global hotkey (default ⇧⌘V)
- **History** — how many items to keep, clear on logout
- **Clipboard** — scan rate (default 100 ms), always paste as plain text, recognize text in
  images (OCR), separator used when pasting a multi-card selection
- **Appearance** — System / Light / Dark theme, panel position, link previews
- **Privacy** — behavior during screen sharing, ignore confidential/transient
  content, a per-app ignore list, and never-save text patterns

## How it works

xPaste polls the system pasteboard on a short interval, classifies each new item,
and stores it locally (images are cached on disk). A Carbon global hotkey opens the
panel; selecting an item writes it back to the pasteboard and simulates ⌘V into the
frontmost app.

The app runs **without the App Sandbox** because it needs full-clipboard access and
the ability to paste into other applications.

## Project layout

```
xPaste/
  App/         AppDelegate, app entry point, hotkey + menu bar
  Models/      ClipboardItem, ClipboardStore (history + persistence)
  Services/    ClipboardMonitor, LinkPreviewService, AccessibilityPermission
  Views/       ContentView (panel), ClipboardItemCard, ItemPreviewWindow, Settings
  Extensions/  NSImage compression, visual-effect blur, date formatting
xPasteTests/   Unit tests
```

---

Private project. © LQ Team.
