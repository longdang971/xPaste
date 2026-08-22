# xPaste

**A clipboard manager for macOS that pastes, not just remembers.** xPaste lives in the menu bar, keeps a searchable history of everything you copy, and puts any of it back into the app you're working in with one keystroke — or one drag.

[![Latest release](https://img.shields.io/github/v/release/longdang971/xPaste?label=Download&style=for-the-badge)](../../releases/latest)

**SwiftUI + AppKit** • macOS 13 (Ventura)+ • No App Sandbox

---

## Highlights

### ⌨️ Recall in one keystroke

Press **⌘⇧V** (rebindable) and the panel slides in over whatever you're doing. **⌘1–⌘9** pastes the card carrying that number, **⌘⇧1–⌘⇧9** pastes it as plain text, **Esc** dismisses. The panel can sit at the top, bottom, left, or right of the screen, and the menu bar icon is optional — the hotkey works either way.

### 🫳 Drag a card out and it's a real paste

Dragging text or a link out of the panel doesn't drop it — it **pastes** it: xPaste activates the app under the pointer, sends a genuine ⌘V, and re-selects what it just inserted through Accessibility. That means it replaces your current selection, which a drop can never do. Images, files, and folders keep a real drag-and-drop, so they still land in Finder or a web upload zone. Hold **⇧** on release to paste as plain text; the clipboard is only written after the drag ends, so cancelling with Esc leaves it untouched.

### 📋 Everything you copy, sorted out for you

Text, links, images, files, folders, and color literals (hex / rgb() / hsl(), shown as swatches) are recognized on capture, along with the app they came from. RTF/HTML formatting is preserved and rendered on the card, with a plain-text path always available.

### 🔍 Search that reaches inside

Free text plus type tokens — `img:`, `link:`, `text:`, `file:`, `folder:` — and `app:safari` to narrow by source. The filter popover adds type, app, and date-range filters as removable tokens. **Screenshots are OCR'd in the background**, so you can find an image by a word written inside it.

### ✂️ Paste As

Paste an item transformed instead of verbatim: **Trimmed, Single Line, UPPERCASE, lowercase, Capitalized, Pretty JSON, Minified JSON, URL Encoded, URL Decoded, Domain Only**. ⌘-click several cards and press **↩** to paste them together, joined by a separator you choose.

### ✏️ Edit, rename, save

**Space** opens a full preview; the pencil (or **Edit…**) fixes the content in place — a typo in a snippet, a stale token in a command. Double-click a card's title to **rename** it, and custom names are searchable. **⌘S** saves an item to disk through a Save dialog, with the extension inferred from the content itself (`.py`, `.json`, `.swift`, `.png`…); a link can be saved as the page it points to.

### 📌 Pins, retention, privacy

Pin what you reuse into its own tab. Keep history for a **day, week, month, year, or forever**, with a stored-item cap of 500–3000 and a one-click erase. xPaste skips content marked confidential or transient, honours a per-app ignore list and your own never-save text patterns, and can hide itself from screen sharing.

### ⬆️ Updates from inside the app

**Check for Updates…** asks GitHub whether there's a newer build, shows the release notes rendered as markdown, then downloads, installs, and relaunches. It only runs when you click it, and a downloaded package that isn't xPaste is rejected rather than installed.

---

## Install

1. Download the latest `xPaste-*.zip` from **[Releases](../../releases/latest)**, unzip it, and drag **xPaste** into **Applications**.
2. Launch it and grant **Accessibility** permission when prompted — pasting into other apps needs it.
   *System Settings → Privacy & Security → Accessibility*
3. If macOS refuses to open the app (it's signed locally, not notarized), right-click → **Open**, or run:

   ```bash
   xattr -cr /Applications/xPaste.app
   ```

Updates keep the same code signature, so the Accessibility grant is not reset.

---

## Build from source

```bash
brew install xcodegen
xcodegen generate

./setup-signing-cert.sh   # once — creates the stable self-signed identity
./build-release.sh        # build, sign, install into /Applications
```

Signing with the same identity every time keeps the app's designated requirement constant, which is what stops macOS from revoking the Accessibility permission on each rebuild.

```bash
xcodebuild test -scheme xPaste -destination 'platform=macOS'
```

---

## How it works

- Polls the system pasteboard (scan rate is configurable) and classifies each new item.
- History and settings live locally; image bytes are cached to disk and pruned with the history.
- The global hotkey is a Carbon hot key, so it fires no matter which app is frontmost.
- Pasting copies the item to the pasteboard and synthesizes ⌘V into the active app; a deferred drag carries a private pasteboard type no app accepts, which is what lets the release become a paste.
- Runs **without the App Sandbox** — full pasteboard access and cross-app pasting need it.

```
xPaste/
├── App/          AppDelegate, panel window, hotkey, updates
├── Models/       ClipboardItem, ClipboardStore, search & filters
├── Services/     Monitor, OCR, link previews, drag-paste, save formats
├── Views/        Panel, cards, preview, settings, onboarding
└── xPasteTests/  Unit tests
```

---

**© LQ Team**
