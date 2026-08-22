# xPaste

A fast, lightweight clipboard manager for macOS. xPaste runs in your menu bar and keeps a searchable history of everything you copy. Retrieve any item with a single keyboard shortcut and paste it instantly.

**Built with SwiftUI + AppKit** • macOS 13.0+ • No App Sandbox

---

## Features

### Core Functionality
- **Clipboard History** — Automatically captures and stores everything you copy
- **Global Shortcut** — Press **Shift ⌘ V** (customizable) to open the panel
- **Smart Classification** — Recognizes Text, Links, Images, Files, Folders, and Colors
- **Drag & Drop** — Drag items from history into Finder, Mail, or any editor
- **Pin & Organize** — Pin frequently used items for quick access

### Smart Content Handling
- **Links** — Live preview with title, image, and favicon
- **Images** — Full preview of screenshots and bitmaps; stored locally
- **Files & Folders** — Auto-detected and distinguishable; drop as real files or paths
- **Colors** — Recognizes hex, rgb(), and hsl() strings; displays as swatches
- **Formatting** — RTF/HTML formatting preserved; plain-text fallback always available

### Search & Filter
- **Search** — Find items by text, type (`text:`, `link:`, `img:`, `file:`, `folder:`), app, or date
- **Filters** — Filter by Type, App, or Date range (Today, This week, Last 30 days, etc.)
- **OCR** — Search text inside screenshots automatically
- **Smart Tokens** — Active filters appear as tokens in the search bar; click to remove

### Paste Options
- **Paste As** — Customize on paste: trimmed, single-line, uppercase/lowercase, JSON-pretty/minified, URL-encoded, or domain-only
- **Batch Paste** — Command-click multiple items and press Enter to paste together with a custom separator
- **Path Paste** — Files/folders paste as both the real file AND the plain-text path

### Editing & Management
- **Rename Items** — Double-click a title to rename it; custom names are searchable
- **Edit Content** — Edit text and links inline; formatting is preserved
- **Save as File** — Export any item to disk with auto-detected file extension (`.py`, `.json`, `.swift`, etc.); links save as HTML
- **Privacy Controls** — Skip confidential content, transient data, or specific apps; define never-save text patterns

### Settings
- **General** — Launch at login, show/hide menu bar icon
- **Shortcuts** — Customize global hotkey
- **History** — Set retention limit, clear on logout
- **Clipboard** — Adjust scan rate, enable plain-text mode, toggle OCR, set multi-paste separator
- **Appearance** — Light/Dark/System theme, panel position, link preview toggle
- **Privacy** — Screen-sharing mode, ignore list, never-save patterns, confidential-content detection

### Updates
- **Manual Check** — Check for new releases on GitHub and install in-place with a single click

---

## Requirements

- **macOS 13.0** (Ventura) or later
- **Accessibility Permission** — Required to paste into other apps  
  Grant via: System Settings → Privacy & Security → Accessibility

---

## Installation

1. **Build the app:**
   ```bash
   brew install xcodegen
   xcodegen generate
   xcodebuild -scheme xPaste -configuration Release -derivedDataPath build clean build
   ```

2. **Install:**
   ```bash
   cp -R build/Build/Products/Release/xPaste.app /Applications/
   open /Applications/xPaste.app
   ```

3. **Grant Accessibility permission** when prompted (or re-grant if it resets after replacement)

---

## Development

**Generate Xcode project from `project.yml`:**
```bash
brew install xcodegen
xcodegen generate
open xPaste.xcodeproj
```

**Run tests:**
```bash
xcodebuild test -scheme xPaste -destination 'platform=macOS'
```

---

## How It Works

- Polls the system pasteboard at regular intervals (configurable, default 100 ms)
- Classifies new items (text, link, image, file, color, etc.)
- Stores clipboard locally; images cached to disk
- Global hotkey (Carbon) opens the panel
- Selecting an item copies it to pasteboard and simulates Cmd V into the active app
- Runs **without App Sandbox** for full clipboard access and inter-app pasting

---

## Project Structure

```
xPaste/
├── App/           AppDelegate, entry point, menu bar, hotkey
├── Models/        ClipboardItem, ClipboardStore (history & persistence)
├── Services/      ClipboardMonitor, LinkPreviewService, AccessibilityPermission
├── Views/         ContentView (panel), Cards, Preview, Settings UI
├── Extensions/    Image compression, visual effects, date formatting
└── xPasteTests/   Unit tests
```

---

**© LQ Team** • Private Project
